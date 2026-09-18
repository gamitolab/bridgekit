// emit/swift.ts — Swift contract file generation from a ContractDescriptor.

import type { RawContractToken } from '../load.js';
import type { EmitResult } from './assemble.js';
import { SwiftCodecWalker, schemaNeedsCodec } from './swift-codec.js';
import {
  escapeSwiftIdentifier,
  SwiftTypeEmitter,
  swiftLiteralForSchema,
  swiftStringLiteral,
} from './swift-types.js';
import {
  type ArrayNode,
  contractIdToClassName,
  hashMember,
  type NullableNode,
  type ObjectNode,
  type OneOfNode,
  type OptionalNode,
  type RecordNode,
  type SchemaNode,
  type TupleNode,
  toPascalCase,
  type UnionNode,
} from './types.js';

export type { EmitResult };

// ---- per-method descriptor shapes ------------------------------------------

interface MethodDescRaw {
  kind: 'fire' | 'query' | 'querySync';
  params?: ObjectNode;
  result?: SchemaNode;
  timeoutMs?: number | null;
}

interface StreamDescRaw {
  kind: 'stream';
  value: SchemaNode;
  params?: ObjectNode;
}

interface StateDescRaw {
  kind: 'state';
  value: SchemaNode;
  initial: unknown;
}

// ---- helpers ---------------------------------------------------------------

const CODEGEN_VERSION = '1';

/**
 * Swift `#if` must wrap a complete declaration. Splitting `class Foo {` across
 * `#endif` then members is a parse error. Duplicate the type: Swift 6 gets
 * `nonisolated` on the header (and on init/inbound/outbound); Swift 5 does not.
 * `#if compiler(>=6)` is wrong: a Swift 6 toolchain in language mode 5 still
 * has compiler≥6 and would emit `nonisolated` where it is illegal.
 */
function pushCompleteTypePair(
  lines: string[],
  headerSwift6: string,
  headerSwift5: string,
  inner: string[],
  innerSwift6: string[] = inner,
): void {
  lines.push('#if swift(>=6.0)');
  lines.push(headerSwift6);
  for (const l of innerSwift6) lines.push(l);
  lines.push('}');
  lines.push('#else');
  lines.push(headerSwift5);
  for (const l of inner) lines.push(l);
  lines.push('}');
  lines.push('#endif');
}

/**
 * Swift 6 `AsyncStream` / `AsyncThrowingStream` builders take a `sending` closure,
 * and `Continuation.yield` takes a `sending` element. Generated pumps therefore
 * cannot capture a non-Sendable host `impl` / `BridgeValue<Any?>` source, and
 * cannot yield wire `Any?` values, without a local transfer.
 *
 * Host protocols stay `AnyObject` (not Sendable). The generated adapter/client is
 * `@unchecked Sendable` because the engine already hops Nitro threads; that is
 * the existing runtime contract, not a new requirement on host implementers.
 * `nonisolated(unsafe)` here only launders the yield, matching that same hop.
 */
function swift6YieldHelpers(): string[] {
  return [
    '#if swift(>=6.0)',
    'nonisolated private func bridgeKitYieldSending<T>(_ continuation: AsyncStream<T>.Continuation, _ value: T) {',
    '    nonisolated(unsafe) let boxed = value',
    '    continuation.yield(boxed)',
    '}',
    'nonisolated private func bridgeKitYieldThrowingSending<T>(_ continuation: AsyncThrowingStream<T, Error>.Continuation, _ value: T) {',
    '    nonisolated(unsafe) let boxed = value',
    '    continuation.yield(boxed)',
    '}',
    '#endif',
    '',
  ];
}

function swiftPumpStem(memberName: string): string {
  return `bk${toPascalCase(memberName)}`;
}

/** Unwrap optional/nullable to the first structured/primitive inner node. */
function unwrapWrappers(node: SchemaNode): SchemaNode {
  let inner = node;
  while (inner.kind === 'optional' || inner.kind === 'nullable') {
    inner = (inner as OptionalNode | NullableNode).inner;
  }
  return inner;
}

// ---- schemaUsesDate --------------------------------------------------------
// Same recursion as Kotlin version — Date/Data both require import Foundation.

function schemaUsesDate(node: SchemaNode | null | undefined): boolean {
  if (!node) return false;
  if (node.kind === 'date' || node.kind === 'binary') return true;
  if (node.kind === 'object') {
    return Object.values((node as ObjectNode).fields).some(schemaUsesDate);
  }
  if (node.kind === 'array') return schemaUsesDate((node as ArrayNode).item);
  if (node.kind === 'optional' || node.kind === 'nullable') {
    return schemaUsesDate((node as OptionalNode | NullableNode).inner);
  }
  if (node.kind === 'record') return schemaUsesDate((node as RecordNode).value);
  if (node.kind === 'union') {
    return Object.values((node as UnionNode).variants).some((variant) =>
      Object.values(variant.fields).some(schemaUsesDate),
    );
  }
  if (node.kind === 'tuple') return (node as TupleNode).items.some(schemaUsesDate);
  if (node.kind === 'oneOf') return (node as OneOfNode).options.some(schemaUsesDate);
  return false;
}

// ---- schemaUsesBoundaryDecodeThrow -----------------------------------------

function schemaUsesBoundaryDecodeThrow(node: SchemaNode | null | undefined): boolean {
  if (!node) return false;
  if (
    node.kind === 'date' ||
    node.kind === 'binary' ||
    node.kind === 'enum' ||
    node.kind === 'int64'
  ) {
    return true;
  }
  if (node.kind === 'object') {
    return Object.values((node as ObjectNode).fields).some(schemaUsesBoundaryDecodeThrow);
  }
  if (node.kind === 'array') return schemaUsesBoundaryDecodeThrow((node as ArrayNode).item);
  if (node.kind === 'optional' || node.kind === 'nullable') {
    return schemaUsesBoundaryDecodeThrow((node as OptionalNode | NullableNode).inner);
  }
  if (node.kind === 'record') return schemaUsesBoundaryDecodeThrow((node as RecordNode).value);
  if (node.kind === 'union') {
    return Object.values((node as UnionNode).variants).some((variant) =>
      Object.values(variant.fields).some(schemaUsesBoundaryDecodeThrow),
    );
  }
  if (node.kind === 'tuple') return (node as TupleNode).items.some(schemaUsesBoundaryDecodeThrow);
  if (node.kind === 'oneOf') return (node as OneOfNode).options.some(schemaUsesBoundaryDecodeThrow);
  return false;
}

// ---- assembleSwiftContractFile ---------------------------------------------

export function assembleSwiftContractFile(parts: {
  fileName: string;
  id: string;
  hash: string;
  className: string;
  codegenVersion: string;
  typeDecls: string[];
  providerMethods: string[];
  clientMethods: string[];
  encodeDecodeFns: string[];
  memberHashPairs: string[];
  inboundImpls: string[];
  syncImpls: string[];
  streamImpls: string[];
  streamImplsSwift6: string[];
  outboundImpls: string[];
  outboundImplsSwift6: string[];
  stateInitials: string[];
  stateFlowEntries: string[];
  stateStreamsSwift6: string[];
  needsFoundationImport: boolean;
  needsBridgeKitDecodeError: boolean;
  moduleName: string;
}): EmitResult {
  const {
    fileName,
    id,
    hash,
    className,
    codegenVersion,
    typeDecls,
    providerMethods,
    clientMethods,
    encodeDecodeFns,
    memberHashPairs,
    inboundImpls,
    syncImpls,
    streamImpls,
    streamImplsSwift6,
    outboundImpls,
    outboundImplsSwift6,
    stateInitials,
    stateFlowEntries,
    stateStreamsSwift6,
    needsFoundationImport,
    needsBridgeKitDecodeError,
    moduleName,
  } = parts;

  const lines: string[] = [];

  // Header
  lines.push(`// Generated by bridgekit ${codegenVersion}. DO NOT EDIT.`);
  lines.push(`// Contract: ${id}`);
  lines.push(`// Contract hash: ${hash}`);
  lines.push('');
  lines.push(`import ${moduleName}`);
  if (needsFoundationImport) {
    lines.push('import Foundation');
  }
  if (needsBridgeKitDecodeError || encodeDecodeFns.length > 0) {
    // BridgeKitDecodeError is part of BridgeKit module; import is already covered.
    // No additional import needed — BridgeKitDecodeError is in BridgeKit.
  }
  lines.push('');
  for (const helperLine of swift6YieldHelpers()) {
    lines.push(helperLine);
  }

  // Type declarations (structs, enums)
  if (typeDecls.length > 0) {
    lines.push('// ---- Types -----------------------------------------------------------------');
    lines.push('');
    for (const decl of typeDecls) {
      lines.push(decl);
      lines.push('');
    }
  }

  // Provider protocol — AnyObject constraint required so BridgeContractDefinition<any P, any C>
  // satisfies P: AnyObject (class-bound existential satisfies AnyObject in Swift 5.7+).
  lines.push('// ---- Provider protocol ------------------------------------------------------');
  lines.push('');
  lines.push(`/// Native-side implementation protocol for contract '${id}'.`);
  pushCompleteTypePair(
    lines,
    `nonisolated protocol ${className}: AnyObject {`,
    `protocol ${className}: AnyObject {`,
    providerMethods,
  );
  lines.push('');

  // Client protocol — same AnyObject constraint.
  lines.push('// ---- Client protocol --------------------------------------------------------');
  lines.push('');
  lines.push(`/// RN-side consumer protocol for contract '${id}'.`);
  pushCompleteTypePair(
    lines,
    `nonisolated protocol ${className}Client: AnyObject {`,
    `protocol ${className}Client: AnyObject {`,
    clientMethods,
  );
  lines.push('');

  // Codec enum (static functions)
  if (encodeDecodeFns.length > 0) {
    lines.push('// ---- Codecs ----------------------------------------------------------------');
    lines.push('');
    const codecInner: string[] = [];
    for (const fn of encodeDecodeFns) {
      for (const l of fn.split('\n')) codecInner.push(l === '' ? '' : `    ${l}`);
      codecInner.push('');
    }
    pushCompleteTypePair(
      lines,
      `nonisolated private enum ${className}Codecs {`,
      `private enum ${className}Codecs {`,
      codecInner,
    );
    lines.push('');
  }

  // Contract definition
  lines.push('// ---- Contract definition ---------------------------------------------------');
  lines.push('');
  // NOTE: id/contractHash/memberHashes are stored properties on the superclass.
  // We must NOT redeclare them as let — that causes a Swift compile error.
  // Instead pass them via super.init(id:contractHash:memberHashes:).
  const hashLines: string[] = [];
  hashLines.push(`        super.init(`);
  hashLines.push(`            id: ${swiftStringLiteral(id)},`);
  hashLines.push(`            contractHash: ${swiftStringLiteral(hash)},`);
  hashLines.push(`            memberHashes: [`);
  for (let i = 0; i < memberHashPairs.length; i++) {
    const comma = i < memberHashPairs.length - 1 ? ',' : '';
    hashLines.push(`                ${memberHashPairs[i]}${comma}`);
  }
  hashLines.push(`            ]`);
  hashLines.push(`        )`);
  const contractInner = [
    `    init() {`,
    ...hashLines,
    `    }`,
    '',
    `    override func inbound(_ impl: any ${className}) -> InboundContractAdapter {`,
    `        return ${className}InboundAdapter(impl: impl)`,
    `    }`,
    '',
    `    override func outbound(_ caller: OutboundCaller) -> any ${className}Client {`,
    `        return ${className}OutboundClient(caller: caller)`,
    `    }`,
  ];
  const contractInnerSwift6 = [
    `    nonisolated init() {`,
    ...hashLines,
    `    }`,
    '',
    `    nonisolated override func inbound(_ impl: any ${className}) -> InboundContractAdapter {`,
    `        return ${className}InboundAdapter(impl: impl)`,
    `    }`,
    '',
    `    nonisolated override func outbound(_ caller: OutboundCaller) -> any ${className}Client {`,
    `        return ${className}OutboundClient(caller: caller)`,
    `    }`,
  ];
  pushCompleteTypePair(
    lines,
    `nonisolated class ${className}Contract: BridgeContractDefinition<any ${className}, any ${className}Client> {`,
    `class ${className}Contract: BridgeContractDefinition<any ${className}, any ${className}Client> {`,
    contractInner,
    contractInnerSwift6,
  );
  lines.push('');

  // Inbound adapter class
  const buildInboundInner = (swift6: boolean): string[] => {
    const inner: string[] = [];
    inner.push(`    let impl: any ${className}`);
    inner.push(
      swift6
        ? `    nonisolated init(impl: any ${className}) { self.impl = impl }`
        : `    init(impl: any ${className}) { self.impl = impl }`,
    );
    inner.push('');
    if (stateInitials.length === 0) {
      inner.push(`    var stateInitials: [String: Any?] { return [:] }`);
    } else {
      inner.push(`    var stateInitials: [String: Any?] { return [`);
      for (const entry of stateInitials) inner.push(`        ${entry}`);
      inner.push(`    ] }`);
    }
    inner.push('');
    inner.push(`    func invoke(member: String, payload: [String: Any?]?) async throws -> Any? {`);
    inner.push(`        switch member {`);
    for (const impl of inboundImpls) {
      for (const l of impl.split('\n')) inner.push(`        ${l}`);
    }
    inner.push(
      `        default: throw BridgeKitDecodeError(field: "member", expectedType: member)`,
    );
    inner.push(`        }`);
    inner.push(`    }`);
    inner.push('');
    inner.push(`    func invokeSync(member: String, payload: [String: Any?]?) throws -> Any? {`);
    inner.push(`        switch member {`);
    for (const impl of syncImpls) {
      for (const l of impl.split('\n')) inner.push(`        ${l}`);
    }
    inner.push(
      `        default: throw BridgeKitDecodeError(field: "member", expectedType: member)`,
    );
    inner.push(`        }`);
    inner.push(`    }`);
    inner.push('');
    inner.push(
      `    func openStream(member: String, payload: [String: Any?]?) -> AsyncThrowingStream<Any?, Error> {`,
    );
    inner.push(`        switch member {`);
    const streamCases = swift6 ? streamImplsSwift6 : streamImpls;
    for (const impl of streamCases) {
      for (const l of impl.split('\n')) inner.push(`        ${l}`);
    }
    inner.push(`        default: return AsyncThrowingStream { $0.finish() }`);
    inner.push(`        }`);
    inner.push(`    }`);
    inner.push('');
    if (stateFlowEntries.length === 0) {
      inner.push(`    func stateStreams() -> [String: AsyncStream<Any?>] { return [:] }`);
    } else if (swift6) {
      for (const l of stateStreamsSwift6) inner.push(l);
    } else {
      inner.push(`    func stateStreams() -> [String: AsyncStream<Any?>] { return [`);
      for (let i = 0; i < stateFlowEntries.length; i++) {
        const comma = i < stateFlowEntries.length - 1 ? ',' : '';
        inner.push(`        ${stateFlowEntries[i]}${comma}`);
      }
      inner.push(`    ] }`);
    }
    return inner;
  };
  pushCompleteTypePair(
    lines,
    `nonisolated private final class ${className}InboundAdapter: InboundContractAdapter, @unchecked Sendable {`,
    `private class ${className}InboundAdapter: InboundContractAdapter {`,
    buildInboundInner(false),
    buildInboundInner(true),
  );
  lines.push('');

  // Outbound client class
  const buildOutboundInner = (swift6: boolean): string[] => {
    const inner: string[] = [
      `    let caller: OutboundCaller`,
      swift6
        ? `    nonisolated init(caller: OutboundCaller) { self.caller = caller }`
        : `    init(caller: OutboundCaller) { self.caller = caller }`,
    ];
    const impls = swift6 ? outboundImplsSwift6 : outboundImpls;
    for (const impl of impls) {
      for (const l of impl.split('\n')) inner.push(`    ${l}`);
    }
    return inner;
  };
  pushCompleteTypePair(
    lines,
    `nonisolated private final class ${className}OutboundClient: ${className}Client, @unchecked Sendable {`,
    `private class ${className}OutboundClient: ${className}Client {`,
    buildOutboundInner(false),
    buildOutboundInner(true),
  );

  return {
    fileName,
    content: `${lines.join('\n')}\n`,
  };
}

// ---- emitSwiftContract -----------------------------------------------------

export function emitSwiftContract(
  token: RawContractToken,
  _contractPackage: string,
  resolvedClassName?: string,
  moduleName: string = 'BridgeKit',
): EmitResult {
  const descriptor = token.descriptor;
  const id = descriptor.id;
  const hash = token.hash;
  const className = resolvedClassName ?? contractIdToClassName(id);
  const fileName = `${className}Contract.swift`;

  const typeEmitter = new SwiftTypeEmitter(className);

  const providerMethods: string[] = [];
  const clientMethods: string[] = [];
  const inboundImpls: string[] = [];
  const syncImpls: string[] = [];
  const streamImpls: string[] = [];
  const streamImplsSwift6: string[] = [];
  const outboundImpls: string[] = [];
  const outboundImplsSwift6: string[] = [];
  const memberHashPairs: string[] = [];
  const encodeDecodeFns: string[] = [];
  const stateInitials: string[] = [];
  const stateFlowEntries: string[] = [];
  const stateStreamsSwift6Setup: string[] = [];
  const stateStreamsSwift6Returns: string[] = [];

  const registeredCodecs = new Set<string>();
  const registerCodecFn = (fn: string): void => {
    const m = fn.match(/^static func (encode|decode)([A-Za-z0-9_]+)\(/);
    const baseName = m ? m[2] : null;
    if (baseName && encodeDecodeFns.some((existing) => existing.includes(`encode${baseName}(`))) {
      return;
    }
    encodeDecodeFns.push(fn);
  };
  const walker = new SwiftCodecWalker(typeEmitter, className, registerCodecFn, registeredCodecs);

  const pushOutboundBoth = (impl: string): void => {
    outboundImpls.push(impl);
    outboundImplsSwift6.push(impl);
  };

  const registerObjectCodec = (dataClassName: string, objNode: ObjectNode): void => {
    if (encodeDecodeFns.some((fn) => fn.includes(`encode${dataClassName}(`))) return;
    registeredCodecs.add(dataClassName);
    encodeDecodeFns.push(walker.emitObjectCodec(dataClassName, objNode));
  };

  // ---- methods ----
  for (const [memberName, rawDesc] of Object.entries(descriptor.methods)) {
    const desc = rawDesc as MethodDescRaw;
    const swiftName = escapeSwiftIdentifier(memberName);
    const memberCtx = toPascalCase(memberName);

    memberHashPairs.push(
      `${swiftStringLiteral(`methods.${memberName}`)}: ${swiftStringLiteral(hashMember(rawDesc))}`,
    );

    if (desc.kind === 'fire') {
      let paramsType = '';
      if (desc.params) {
        const dataClassName = `${memberCtx}Params`;
        const paramsResult = typeEmitter.emit(desc.params, dataClassName);
        paramsType = paramsResult.typeName;
        registerObjectCodec(paramsType, desc.params);
      }

      const paramSig = paramsType ? `_ params: ${paramsType}` : '';
      providerMethods.push(`    func ${swiftName}(${paramSig})`);
      clientMethods.push(`    func ${swiftName}(${paramSig})`);

      // inbound
      if (paramsType) {
        inboundImpls.push(
          [
            `case ${swiftStringLiteral(memberName)}:`,
            `    let decoded = try ${className}Codecs.decode${paramsType}(payload ?? [:])`,
            `    impl.${swiftName}(decoded)`,
            `    return nil`,
          ].join('\n'),
        );
      } else {
        inboundImpls.push(
          `case ${swiftStringLiteral(memberName)}: impl.${swiftName}(); return nil`,
        );
      }

      // outbound
      if (paramsType) {
        pushOutboundBoth(
          [
            `func ${swiftName}(_ params: ${paramsType}) {`,
            `    caller.fire(member: ${swiftStringLiteral(memberName)}, payload: ${className}Codecs.encode${paramsType}(params))`,
            `}`,
          ].join('\n'),
        );
      } else {
        pushOutboundBoth(
          `func ${swiftName}() { caller.fire(member: ${swiftStringLiteral(memberName)}, payload: nil) }`,
        );
      }
    } else if (desc.kind === 'query' || desc.kind === 'querySync') {
      let paramsType = '';
      let resultType = 'Void';

      if (desc.params) {
        const dataClassName = `${memberCtx}Params`;
        const paramsResult = typeEmitter.emit(desc.params, dataClassName);
        paramsType = paramsResult.typeName;
      }

      const resultCtx = `${memberCtx}Result`;
      if (desc.result) {
        const res = typeEmitter.emit(desc.result, resultCtx);
        resultType = res.typeName;
      }

      const paramSig = paramsType ? `_ params: ${paramsType}` : '';
      const asyncMod = desc.kind === 'query' ? 'async ' : '';

      providerMethods.push(`    func ${swiftName}(${paramSig}) ${asyncMod}throws -> ${resultType}`);
      clientMethods.push(`    func ${swiftName}(${paramSig}) ${asyncMod}throws -> ${resultType}`);

      const invokeCall = desc.kind === 'querySync' ? 'invokeSync' : 'invoke';
      const encodeParams = paramsType ? `${className}Codecs.encode${paramsType}(params)` : 'nil';
      const isNullableResult = resultType.endsWith('?');

      // inbound
      if (desc.kind === 'querySync') {
        // Provider Sync methods are declared `throws`; use `try` here.
        const inboundCallExprBase = paramsType
          ? `try impl.${swiftName}(decoded)`
          : `try impl.${swiftName}()`;
        const inboundResultExpr = desc.result
          ? buildSwiftInboundEncodeExpr(desc.result, inboundCallExprBase, resultCtx, walker)
          : inboundCallExprBase;
        const body: string[] = [`case ${swiftStringLiteral(memberName)}:`];
        if (paramsType) {
          body.push(`    let decoded = try ${className}Codecs.decode${paramsType}(payload ?? [:])`);
        }
        body.push(`    return ${inboundResultExpr}`);
        syncImpls.push(body.join('\n'));
      } else {
        const inboundCallExprBase = paramsType
          ? `impl.${swiftName}(decoded)`
          : `impl.${swiftName}()`;
        // Provider async methods are declared `async throws`; use `try await` here.
        // The outer func is also `async throws`, so `try` propagates naturally.
        const inboundResultExpr = desc.result
          ? buildSwiftInboundEncodeExpr(
              desc.result,
              `try await ${inboundCallExprBase}`,
              resultCtx,
              walker,
            )
          : `try await ${inboundCallExprBase}`;
        const body: string[] = [`case ${swiftStringLiteral(memberName)}:`];
        if (paramsType) {
          body.push(`    let decoded = try ${className}Codecs.decode${paramsType}(payload ?? [:])`);
        }
        body.push(`    return ${inboundResultExpr}`);
        inboundImpls.push(body.join('\n'));
      }

      // outbound return
      const returnLines = buildSwiftOutboundReturnLines(
        desc.result ?? null,
        resultType,
        isNullableResult,
        memberName,
        resultCtx,
        walker,
      );

      if (desc.kind === 'querySync') {
        pushOutboundBoth(
          [
            `func ${swiftName}(${paramSig}) throws -> ${resultType} {`,
            `    let result = try caller.${invokeCall}(member: ${swiftStringLiteral(memberName)}, payload: ${encodeParams})`,
            ...returnLines,
            `}`,
          ].join('\n'),
        );
      } else {
        pushOutboundBoth(
          [
            `func ${swiftName}(${paramSig}) async throws -> ${resultType} {`,
            `    let result = try await caller.${invokeCall}(member: ${swiftStringLiteral(memberName)}, payload: ${encodeParams})`,
            ...returnLines,
            `}`,
          ].join('\n'),
        );
      }

      if (paramsType && desc.params) {
        registerObjectCodec(paramsType, desc.params);
      }
    }
  }

  // ---- streams ----
  for (const [memberName, rawDesc] of Object.entries(descriptor.streams)) {
    const desc = rawDesc as StreamDescRaw;
    const swiftName = escapeSwiftIdentifier(memberName);
    const memberCtx = toPascalCase(memberName);
    const valueResult = typeEmitter.emit(desc.value, `${memberCtx}Value`);
    const streamType = `AsyncStream<${valueResult.typeName}>`;

    memberHashPairs.push(
      `${swiftStringLiteral(`streams.${memberName}`)}: ${swiftStringLiteral(hashMember(rawDesc))}`,
    );

    let streamParamsType = '';
    if (desc.params) {
      const dataClassName = `${memberCtx}Params`;
      const paramsResult = typeEmitter.emit(desc.params, dataClassName);
      streamParamsType = paramsResult.typeName;
      registerObjectCodec(streamParamsType, desc.params);
    }

    const paramSig = streamParamsType ? `_ params: ${streamParamsType}` : '';
    providerMethods.push(`    func ${swiftName}(${paramSig}) -> ${streamType}`);
    clientMethods.push(`    func ${swiftName}(${paramSig}) -> ${streamType}`);

    const encodeStreamParams = streamParamsType
      ? `${className}Codecs.encode${streamParamsType}(params)`
      : 'nil';

    const valueCtx = `${memberCtx}Value`;
    // caller.stream() returns AsyncThrowingStream<Any?, Error>. Bridge it to AsyncStream<T>
    // by decoding each element. AsyncStream cannot propagate failure, so report the
    // decode/transport error before terminating the non-throwing client stream.
    const decodeStreamItem = walker.decodeExpr('item', desc.value, valueCtx, `${swiftName}.value`);
    outboundImpls.push(
      [
        `func ${swiftName}(${paramSig}) -> ${streamType} {`,
        `    let throwing = caller.stream(member: ${swiftStringLiteral(memberName)}, payload: ${encodeStreamParams})`,
        `    return AsyncStream { cont in Task { do { for try await item in throwing { cont.yield(${decodeStreamItem}) } } catch { bridgeKitReportDecodeError(error, context: ${swiftStringLiteral(`stream.${memberName}`)}); cont.finish() } } }`,
        `}`,
      ].join('\n'),
    );
    outboundImplsSwift6.push(
      [
        `func ${swiftName}(${paramSig}) -> ${streamType} {`,
        `    let (stream, continuation) = AsyncStream<${valueResult.typeName}>.makeStream()`,
        `    let pump = Task {`,
        `        do {`,
        `            for try await item in self.caller.stream(member: ${swiftStringLiteral(memberName)}, payload: ${encodeStreamParams}) {`,
        `                bridgeKitYieldSending(continuation, ${decodeStreamItem})`,
        `            }`,
        `            continuation.finish()`,
        `        } catch {`,
        `            bridgeKitReportDecodeError(error, context: ${swiftStringLiteral(`stream.${memberName}`)})`,
        `            continuation.finish()`,
        `        }`,
        `    }`,
        `    continuation.onTermination = { _ in pump.cancel() }`,
        `    return stream`,
        `}`,
      ].join('\n'),
    );

    // inbound openStream: provider returns AsyncStream<T>, protocol requires AsyncThrowingStream<Any?, Error>.
    // Bridge by wrapping the provider's AsyncStream in a non-throwing stream yielded into the throwing one.
    const decodeParamsExpr = streamParamsType
      ? `${className}Codecs.decode${streamParamsType}(payload ?? [:])`
      : '';
    const callExpr = streamParamsType
      ? `impl.${swiftName}(${decodeParamsExpr})`
      : `impl.${swiftName}()`;
    const swift6CallExpr = streamParamsType
      ? `self.impl.${swiftName}(decoded)`
      : `self.impl.${swiftName}()`;
    const encodeItem = schemaNeedsCodec(desc.value)
      ? walker.encodeExpr('item', desc.value, valueCtx)
      : 'item';
    streamImpls.push(
      [
        `case ${swiftStringLiteral(memberName)}:`,
        `    let src = ${callExpr}`,
        `    return AsyncThrowingStream { cont in Task { for await item in src { cont.yield(${encodeItem}) }; cont.finish() } }`,
      ].join('\n'),
    );
    const swift6StreamCase: string[] = [`case ${swiftStringLiteral(memberName)}:`];
    if (streamParamsType) {
      swift6StreamCase.push(`    let decoded = ${decodeParamsExpr}`);
    }
    swift6StreamCase.push(
      `    let (stream, continuation) = AsyncThrowingStream<Any?, Error>.makeStream()`,
      `    let pump = Task {`,
      `        for await item in ${swift6CallExpr} {`,
      `            bridgeKitYieldThrowingSending(continuation, ${encodeItem})`,
      `        }`,
      `        continuation.finish()`,
      `    }`,
      `    continuation.onTermination = { _ in pump.cancel() }`,
      `    return stream`,
    );
    streamImplsSwift6.push(swift6StreamCase.join('\n'));
  }

  // ---- state ----
  for (const [memberName, rawDesc] of Object.entries(descriptor.state)) {
    const desc = rawDesc as StateDescRaw;
    const swiftName = escapeSwiftIdentifier(memberName);
    const memberCtx = toPascalCase(memberName);
    const valueResult = typeEmitter.emit(desc.value, memberCtx);

    memberHashPairs.push(
      `${swiftStringLiteral(`state.${memberName}`)}: ${swiftStringLiteral(hashMember(rawDesc))}`,
    );

    stateInitials.push(
      `${swiftStringLiteral(memberName)}: ${swiftLiteralForSchema(desc.initial, desc.value, `state.${memberName}.initial`)},`,
    );

    providerMethods.push(`    var ${swiftName}: AsyncStream<${valueResult.typeName}> { get }`);
    clientMethods.push(
      `    var ${swiftName}: AsyncStream<BridgeValue<${valueResult.typeName}>> { get }`,
    );

    // stateFlowEntries are emitted inside the INBOUND adapter (no `caller`).
    // Bridge the provider's AsyncStream<T> to AsyncStream<Any?> via a wrapping stream.
    const encodeStateValue = schemaNeedsCodec(desc.value)
      ? walker.encodeExpr('v', desc.value, memberCtx)
      : 'v';
    stateFlowEntries.push(
      `${swiftStringLiteral(memberName)}: AsyncStream<Any?> { cont in Task { for await v in self.impl.${swiftName} { cont.yield(${encodeStateValue}) }; cont.finish() } }`,
    );
    const stem = swiftPumpStem(memberName);
    stateStreamsSwift6Setup.push(
      `let (${stem}Stream, ${stem}Cont) = AsyncStream<Any?>.makeStream()`,
      `let ${stem}Pump = Task {`,
      `    for await v in self.impl.${swiftName} {`,
      `        bridgeKitYieldSending(${stem}Cont, ${encodeStateValue})`,
      `    }`,
      `    ${stem}Cont.finish()`,
      `}`,
      `${stem}Cont.onTermination = { _ in ${stem}Pump.cancel() }`,
    );
    stateStreamsSwift6Returns.push(`${swiftStringLiteral(memberName)}: ${stem}Stream`);

    // caller.state() yields AsyncStream<BridgeValue<Any?>>. AsyncStream is an
    // invariant generic struct, so `as! AsyncStream<BridgeValue<T>>` traps at
    // runtime. Re-type element-by-element via BridgeValue.remap, decoding the
    // carried value with the walker (handles numeric coercion + composite codecs).
    const decodeStateValue = walker.decodeExpr(
      'value',
      desc.value,
      memberCtx,
      `${swiftName}.value`,
    );
    const remapYield = [
      `bv.remap { (value: Any?) -> ${valueResult.typeName}? in`,
      `                    do { return ${decodeStateValue} }`,
      `                    catch { bridgeKitReportDecodeError(error, context: ${swiftStringLiteral(`state.${memberName}`)}); return nil }`,
      `                }`,
    ].join('\n');
    outboundImpls.push(
      [
        `var ${swiftName}: AsyncStream<BridgeValue<${valueResult.typeName}>> {`,
        `    let source = caller.state(member: ${swiftStringLiteral(memberName)})`,
        `    return AsyncStream { cont in`,
        `        let pump = Task {`,
        `            for await bv in source {`,
        `                cont.yield(${remapYield})`,
        `            }`,
        `            cont.finish()`,
        `        }`,
        `        cont.onTermination = { _ in pump.cancel() }`,
        `    }`,
        `}`,
      ].join('\n'),
    );
    outboundImplsSwift6.push(
      [
        `var ${swiftName}: AsyncStream<BridgeValue<${valueResult.typeName}>> {`,
        `    let (stream, continuation) = AsyncStream<BridgeValue<${valueResult.typeName}>>.makeStream()`,
        `    let pump = Task {`,
        `        for await bv in self.caller.state(member: ${swiftStringLiteral(memberName)}) {`,
        `            bridgeKitYieldSending(continuation, ${remapYield})`,
        `        }`,
        `        continuation.finish()`,
        `    }`,
        `    continuation.onTermination = { _ in pump.cancel() }`,
        `    return stream`,
        `}`,
      ].join('\n'),
    );
  }

  const stateStreamsSwift6: string[] = [];
  if (stateFlowEntries.length > 0) {
    stateStreamsSwift6.push(`    func stateStreams() -> [String: AsyncStream<Any?>] {`);
    for (const l of stateStreamsSwift6Setup) {
      stateStreamsSwift6.push(`        ${l}`);
    }
    stateStreamsSwift6.push(`        return [`);
    for (let i = 0; i < stateStreamsSwift6Returns.length; i++) {
      const comma = i < stateStreamsSwift6Returns.length - 1 ? ',' : '';
      stateStreamsSwift6.push(`            ${stateStreamsSwift6Returns[i]}${comma}`);
    }
    stateStreamsSwift6.push(`        ]`);
    stateStreamsSwift6.push(`    }`);
  }

  const needsFoundationImport =
    Object.values(descriptor.methods).some((m) => {
      const d = m as MethodDescRaw;
      return schemaUsesDate(d.params ?? null) || schemaUsesDate(d.result ?? null);
    }) ||
    Object.values(descriptor.streams).some((s) => schemaUsesDate((s as StreamDescRaw).value)) ||
    Object.values(descriptor.state).some((s) => schemaUsesDate((s as StateDescRaw).value));

  const needsBridgeKitDecodeError =
    Object.values(descriptor.methods).some((m) => {
      const d = m as MethodDescRaw;
      return schemaUsesBoundaryDecodeThrow(d.result ?? null);
    }) ||
    Object.values(descriptor.streams).some((s) =>
      schemaUsesBoundaryDecodeThrow((s as StreamDescRaw).value),
    ) ||
    Object.values(descriptor.state).some((s) =>
      schemaUsesBoundaryDecodeThrow((s as StateDescRaw).value),
    );

  return assembleSwiftContractFile({
    fileName,
    id,
    hash,
    className,
    codegenVersion: CODEGEN_VERSION,
    typeDecls: typeEmitter.getDeclarations(),
    providerMethods,
    clientMethods,
    encodeDecodeFns,
    memberHashPairs,
    inboundImpls,
    syncImpls,
    streamImpls,
    streamImplsSwift6,
    outboundImpls,
    outboundImplsSwift6,
    stateInitials,
    stateFlowEntries,
    stateStreamsSwift6,
    needsFoundationImport,
    needsBridgeKitDecodeError,
    moduleName,
  });
}

// ---- outbound return expression builders -----------------------------------

function buildSwiftOutboundReturnLines(
  resultSchema: SchemaNode | null,
  resultType: string,
  isNullable: boolean,
  _memberName: string,
  resultCtx: string,
  walker: SwiftCodecWalker,
): string[] {
  if (!resultSchema || resultType === 'Void') return [`    return`];

  const innerSchema = unwrapWrappers(resultSchema);
  const decodeExpr = walker.boundaryDecode('result', innerSchema, resultCtx);
  if (isNullable) {
    return [`    return result == nil ? nil : (${decodeExpr})`];
  }
  return [`    return ${decodeExpr}`];
}

function buildSwiftInboundEncodeExpr(
  resultSchema: SchemaNode,
  callExpr: string,
  resultCtx: string,
  walker: SwiftCodecWalker,
): string {
  const inner = unwrapWrappers(resultSchema);
  if (inner.kind === 'void' || !schemaNeedsCodec(inner)) return callExpr;
  const isNullable = resultSchema.kind === 'optional' || resultSchema.kind === 'nullable';
  if (isNullable) {
    return `${callExpr}.map { ${walker.boundaryEncode('$0', inner, resultCtx)} }`;
  }
  return walker.boundaryEncode(callExpr, inner, resultCtx);
}
