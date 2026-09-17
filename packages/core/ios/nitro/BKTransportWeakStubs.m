// Weak fallbacks so BridgeKitNitro can link without the public BridgeKit pod.
// The public module compiles strong BKTransport.m; the app linker prefers those.

#import "../seam/BKTransport.h"

#define BK_WEAK __attribute__((weak))

BK_WEAK void BKTransportInstall(BKTransportHooks *_Nullable hooks) {
  (void)hooks;
}

BK_WEAK BKTransportHooks *_Nullable BKTransportGet(void) {
  return nil;
}

static NSDictionary *BKWeakNotReady(void) {
  return @{
    @"ok": @NO,
    @"code": @"BRIDGE_NOT_READY",
    @"message": @"BridgeKit transport is not registered. Provide() on the host, then start React Native."
  };
}

BK_WEAK void BKTransportInvoke(NSDictionary *env, BKDictCallback complete) {
  (void)env;
  complete(BKWeakNotReady());
}

BK_WEAK NSDictionary *BKTransportInvokeSync(NSDictionary *env) {
  (void)env;
  return BKWeakNotReady();
}

BK_WEAK NSDictionary *BKTransportConnectDispatcher(
    NSDictionary *epochInfo,
    BKInvokeHandler onInvoke,
    BKDictHandler onStreamOpen,
    BKDictHandler onStreamClose,
    BKDictHandler onStateWrite
) {
  (void)epochInfo;
  (void)onInvoke;
  (void)onStreamOpen;
  (void)onStreamClose;
  (void)onStateWrite;
  return @{@"epoch": @0, @"snapshot": @[]};
}

BK_WEAK NSString *BKTransportOpenStream(NSDictionary *env, BKDictCallback onNext, BKDictCallback onEnd) {
  (void)env;
  (void)onNext;
  onEnd(BKWeakNotReady());
  return @"";
}

BK_WEAK void BKTransportCloseStream(NSString *streamId) { (void)streamId; }
BK_WEAK void BKTransportEmitFromJs(NSString *streamId, NSDictionary *value) {
  (void)streamId;
  (void)value;
}
BK_WEAK void BKTransportEndFromJs(NSString *streamId, NSDictionary *end) {
  (void)streamId;
  (void)end;
}

BK_WEAK NSDictionary *BKTransportStateRead(NSDictionary *env) {
  (void)env;
  return BKWeakNotReady();
}

BK_WEAK NSString *BKTransportStateObserve(NSDictionary *env, BKDictCallback onChange) {
  (void)env;
  (void)onChange;
  return @"";
}

BK_WEAK void BKTransportStateUnobserve(NSString *obsId) { (void)obsId; }

BK_WEAK NSDictionary *BKTransportStateWrite(NSDictionary *env) {
  (void)env;
  return BKWeakNotReady();
}
