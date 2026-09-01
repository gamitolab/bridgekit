package com.bridgekit.core

import com.bridgekit.runtime.InboundContractAdapter
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.onSubscription
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

// StreamHub — multiplexes one provider Flow across N consumers keyed by
// (contractId, member, scope, paramsHash).
//
// Shares ONE provider invocation across all consumers with identical params.
// A second consumer subscribing while one is already running attaches to the
// existing SharedFlow fan-out; the upstream Flow is cancelled only when the
// last consumer detaches (refcount).
//
// `latestOnly` or `sticky` descriptors use replay = 1 on the SharedFlow
// so a late subscriber immediately receives the last emitted item.
//
// Lifecycle invariants (these are what the quarantined WS-5 tests were
// tripping over):
//
//   1. The upstream is started from INSIDE the first consumer's collector, after
//      its SharedFlow subscription is registered (`onSubscription`). A provider
//      that emits synchronously can therefore never race ahead of the consumer
//      that opened it: with replay = 0 an emission before subscription is simply
//      dropped, and the first consumer used to lose the head of its own stream.
//   2. A hub entry is closed exactly once — by the upstream terminating or by
//      the last consumer leaving — and is never revived. A later attach for the
//      same key gets a fresh entry and a fresh provider invocation instead of
//      joining a dead one and receiving a stale terminal.
//   3. Terminal delivery is exactly-once per consumer whether the terminal
//      arrives through the SharedFlow or was stored before the consumer
//      subscribed. Consumers end themselves by throwing CancellationException
//      from their own collector, so there is no `lateinit` Job to read before
//      `launch` has returned.

internal class StreamHub(
    private val engineScope: CoroutineScope,
) {
    /** Capacity of the upstream buffer before DROP_OLDEST. Mirrors Router STREAM_BUFFER_CAPACITY. */
    private val UPSTREAM_BUFFER = 64

    private data class HubKey(
        val contractId: String,
        val member: String,
        val scopeKey: String,
        val paramsHash: Long,
    )

    private inner class HubEntry(
        val key: HubKey,
        val sharedFlow: MutableSharedFlow<Any?>,
        val adapter: InboundContractAdapter,
        val payload: Map<String, Any?>?,
    ) {
        // refCount, upstreamJob and closed are guarded by synchronized(this).
        var refCount = 0
        var upstreamJob: Job? = null

        /**
         * Set once, never cleared: the upstream terminated or the last consumer left.
         * A closed entry is unreachable from [hubs] for new attaches. Volatile so the
         * lock-free `compute` in [acquire] can read it.
         */
        @Volatile
        var closed = false

        /**
         * HUB_TERMINAL_OK or HubTerminalError once the upstream terminated. Written
         * BEFORE the terminal is emitted on [sharedFlow], so a consumer that subscribes
         * after the emission was dropped still finds it here.
         */
        @Volatile
        var terminal: Any? = null
    }

    private val hubs = ConcurrentHashMap<HubKey, HubEntry>()

    /**
     * Attach a consumer to the shared stream for (contractId, member, scope, paramsHash).
     *
     * If no live hub entry exists for this key, one is created and the upstream provider
     * Flow is started by this consumer once its subscription is registered. On completion
     * or cancellation of the returned Job the consumer is released; when the last consumer
     * leaves, the upstream Job is cancelled and the entry is removed.
     *
     * @param contractId  The contract identifier.
     * @param member      The stream member name.
     * @param scope       The binding scope.
     * @param paramsHash  Deterministic hash of encoded params (use stableHash key-sorting).
     * @param adapter     The inbound adapter for this binding (provides the upstream Flow).
     * @param payload     The raw params map forwarded to the adapter's openStream.
     * @param streamEpoch The epoch at which this stream was opened (tracked by Router).
     * @param streamId    Unique stream ID for epoch tracking in streamPumpJobs (tracked by Router).
     * @param latestOnly  If true, replay = 1 (late subscriber gets last value).
     * @param sticky      Alias for latestOnly.
     * @param onNext      JS consumer callback for each item.
     * @param onEnd       JS consumer callback on stream termination.
     * @return the consumer collection Job. Cancelling it (e.g. Router.closeStream,
     *         epoch swap, or scope cancellation) automatically detaches this consumer
     *         from the hub, releasing the upstream when the last consumer leaves.
     */
    @Suppress("UNUSED_PARAMETER")
    fun attach(
        contractId: String,
        member: String,
        scope: Scope,
        paramsHash: Long,
        adapter: InboundContractAdapter,
        payload: Map<String, Any?>?,
        streamEpoch: Long,
        streamId: String,
        latestOnly: Boolean = false,
        sticky: Boolean = false,
        onNext: (Map<String, Any?>) -> Unit,
        onEnd: (Map<String, Any?>) -> Unit,
    ): Job {
        val key = HubKey(contractId, member, scope.serialize(), paramsHash)
        val replay = if (latestOnly || sticky) 1 else 0
        val entry = acquire(key, replay, adapter, payload)

        val terminalFired = AtomicBoolean(false)
        fun deliverTerminal(terminal: Any?) {
            if (terminalFired.compareAndSet(false, true)) {
                onEnd(terminalEnvelope(terminal, contractId, member, scope))
            }
        }

        val consumerJob = engineScope.launch {
            entry.sharedFlow
                .onSubscription {
                    // The subscription is registered: every emission from here on reaches
                    // this collector. Only now is it safe to start the provider.
                    startUpstreamIfNeeded(entry)
                    // If the upstream already terminated, its terminal emission either
                    // happened before we subscribed (replay = 0: dropped) or is about to be
                    // replayed (replay = 1). Deliver from the stored value and stop; the CAS
                    // keeps it to exactly one either way.
                    entry.terminal?.let { stored ->
                        deliverTerminal(stored)
                        throw CancellationException("terminal-before-subscribe")
                    }
                }
                .collect { value ->
                    when {
                        value === HUB_TERMINAL_OK || value is HubTerminalError -> {
                            deliverTerminal(value)
                            // Ends this collector. A SharedFlow never completes on its own,
                            // so the consumer has to leave.
                            throw CancellationException("terminal")
                        }
                        else -> onNext(mapOf("v" to value))
                    }
                }
        }

        // Tie the hub refcount to the consumer job lifecycle. On completion or cancellation,
        // release decrements the refcount and cancels the upstream when the last consumer leaves.
        consumerJob.invokeOnCompletion { release(entry) }

        return consumerJob
    }

    /**
     * Detach one consumer of the live entry for this key. Decrements the refcount; cancels
     * the upstream and removes the entry when the last consumer leaves.
     *
     * Router does not call this — cancelling the Job returned by [attach] is the
     * production detach path. It is kept for direct hub tests.
     */
    fun detach(contractId: String, member: String, scope: Scope, paramsHash: Long) {
        val key = HubKey(contractId, member, scope.serialize(), paramsHash)
        val entry = hubs[key] ?: return
        release(entry)
    }

    /** Cancel all active hub entries (called on epoch swap). */
    fun cancelAll() {
        for (entry in hubs.values) {
            synchronized(entry) { entry.closed = true }
            entry.upstreamJob?.cancel()
        }
        hubs.clear()
    }

    // ---- entry lifecycle -----------------------------------------------------------

    /** Returns a live entry for [key] with this consumer's reference counted in. */
    private fun acquire(
        key: HubKey,
        replay: Int,
        adapter: InboundContractAdapter,
        payload: Map<String, Any?>?,
    ): HubEntry {
        while (true) {
            // Atomic per key: a closed entry is replaced, never joined. A later attach for
            // a key whose stream already completed gets a fresh provider invocation.
            val entry = hubs.compute(key) { _, existing ->
                if (existing == null || existing.closed) {
                    HubEntry(
                        key = key,
                        sharedFlow = MutableSharedFlow(
                            replay = replay,
                            extraBufferCapacity = UPSTREAM_BUFFER,
                            onBufferOverflow = BufferOverflow.DROP_OLDEST,
                        ),
                        adapter = adapter,
                        payload = payload,
                    )
                } else {
                    existing
                }
            }!!
            synchronized(entry) {
                // Lost the race against the last consumer leaving or the upstream
                // terminating between compute() and here: retry with a fresh entry.
                if (entry.closed) return@synchronized
                entry.refCount++
                return entry
            }
        }
    }

    private fun release(entry: HubEntry) {
        val last: Boolean
        synchronized(entry) {
            if (entry.closed) return
            entry.refCount--
            last = entry.refCount <= 0
            if (last) entry.closed = true
        }
        if (last) {
            // Value-aware remove — only remove THIS entry, never a live replacement
            // registered under the same key.
            hubs.remove(entry.key, entry)
            entry.upstreamJob?.cancel()
        }
    }

    private fun startUpstreamIfNeeded(entry: HubEntry) {
        synchronized(entry) {
            if (entry.closed || entry.upstreamJob != null) return
            entry.upstreamJob = engineScope.launch {
                // The try/catch classifies completion as exactly one terminal —
                // HubTerminalError on failure, HUB_TERMINAL_OK on normal completion — and
                // rethrows CancellationException for cooperative cancel (epoch swap,
                // last-consumer-detach), which emits no terminal: the consumers are
                // already being cancelled.
                try {
                    val flow = entry.adapter.openStream(entry.key.member, entry.payload)
                    flow
                        .buffer(UPSTREAM_BUFFER, BufferOverflow.DROP_OLDEST)
                        // No .catch here — errors must reach the outer catch so we can
                        // emit HubTerminalError instead of silently emitting HUB_TERMINAL_OK.
                        .collect { value -> entry.sharedFlow.emit(value) }
                    finish(entry, HUB_TERMINAL_OK)
                } catch (ce: CancellationException) {
                    throw ce
                } catch (e: Throwable) {
                    finish(entry, HubTerminalError(e.message ?: "Stream error"))
                }
            }
        }
    }

    private suspend fun finish(entry: HubEntry, terminal: Any) {
        // Order matters: store the terminal and close the entry BEFORE emitting, so a
        // consumer subscribing after the emission finds the stored terminal, and an attach
        // arriving after completion gets a fresh entry instead of this dead one.
        entry.terminal = terminal
        synchronized(entry) { entry.closed = true }
        hubs.remove(entry.key, entry)
        entry.sharedFlow.emit(terminal)
    }

    private fun terminalEnvelope(
        terminal: Any?,
        contractId: String,
        member: String,
        scope: Scope,
    ): Map<String, Any?> = when (terminal) {
        is HubTerminalError -> mapOf(
            "ok" to false,
            "code" to "PROVIDER_ERROR",
            "message" to terminal.message,
            "contractId" to contractId,
            "member" to member,
            "scope" to mapOf("kind" to scope.serialize()),
        )
        else -> mapOf("ok" to true, "value" to null)
    }

    companion object {
        /** Sentinel object indicating normal stream completion from upstream. */
        internal val HUB_TERMINAL_OK: Any = object : Any() {}
    }

    internal data class HubTerminalError(val message: String)
}
