// BKTransport.m — strong implementation. Compile only into the public BridgeKit pod/SPM.

#import "BKTransport.h"

@implementation BKTransportHooks
@end

static BKTransportHooks *_Nullable BKTransportHooksCurrent = nil;
static NSLock *BKTransportLock(void) {
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    lock = [[NSLock alloc] init];
  });
  return lock;
}

static NSDictionary *BKNotReady(void) {
  return @{
    @"ok": @NO,
    @"code": @"BRIDGE_NOT_READY",
    @"message": @"BridgeKit transport is not registered. Provide() on the host, then start React Native."
  };
}

void BKTransportInstall(BKTransportHooks *_Nullable hooks) {
  [BKTransportLock() lock];
  BKTransportHooksCurrent = hooks;
  [BKTransportLock() unlock];
}

BKTransportHooks *_Nullable BKTransportGet(void) {
  [BKTransportLock() lock];
  BKTransportHooks *hooks = BKTransportHooksCurrent;
  [BKTransportLock() unlock];
  return hooks;
}

void BKTransportInvoke(NSDictionary *env, BKDictCallback complete) {
  BKTransportHooks *hooks = BKTransportGet();
  if (hooks.invoke == nil) {
    complete(BKNotReady());
    return;
  }
  hooks.invoke(env, complete);
}

NSDictionary *BKTransportInvokeSync(NSDictionary *env) {
  BKTransportHooks *hooks = BKTransportGet();
  if (hooks.invokeSync == nil) {
    return BKNotReady();
  }
  return hooks.invokeSync(env);
}

NSDictionary *BKTransportConnectDispatcher(
    NSDictionary *epochInfo,
    BKInvokeHandler onInvoke,
    BKDictHandler onStreamOpen,
    BKDictHandler onStreamClose,
    BKDictHandler onStateWrite
) {
  BKTransportHooks *hooks = BKTransportGet();
  if (hooks.connectDispatcher == nil) {
    return @{@"epoch": @0, @"snapshot": @[]};
  }
  return hooks.connectDispatcher(epochInfo, onInvoke, onStreamOpen, onStreamClose, onStateWrite);
}

NSString *BKTransportOpenStream(NSDictionary *env, BKDictCallback onNext, BKDictCallback onEnd) {
  BKTransportHooks *hooks = BKTransportGet();
  if (hooks.openStream == nil) {
    onEnd(BKNotReady());
    return @"";
  }
  return hooks.openStream(env, onNext, onEnd);
}

void BKTransportCloseStream(NSString *streamId) {
  BKTransportHooks *hooks = BKTransportGet();
  if (hooks.closeStream != nil) {
    hooks.closeStream(streamId);
  }
}

void BKTransportEmitFromJs(NSString *streamId, NSDictionary *value) {
  BKTransportHooks *hooks = BKTransportGet();
  if (hooks.emitFromJs != nil) {
    hooks.emitFromJs(streamId, value);
  }
}

void BKTransportEndFromJs(NSString *streamId, NSDictionary *end) {
  BKTransportHooks *hooks = BKTransportGet();
  if (hooks.endFromJs != nil) {
    hooks.endFromJs(streamId, end);
  }
}

NSDictionary *BKTransportStateRead(NSDictionary *env) {
  BKTransportHooks *hooks = BKTransportGet();
  if (hooks.stateRead == nil) {
    return BKNotReady();
  }
  return hooks.stateRead(env);
}

NSString *BKTransportStateObserve(NSDictionary *env, BKDictCallback onChange) {
  BKTransportHooks *hooks = BKTransportGet();
  if (hooks.stateObserve == nil) {
    return @"";
  }
  return hooks.stateObserve(env, onChange);
}

void BKTransportStateUnobserve(NSString *obsId) {
  BKTransportHooks *hooks = BKTransportGet();
  if (hooks.stateUnobserve != nil) {
    hooks.stateUnobserve(obsId);
  }
}

NSDictionary *BKTransportStateWrite(NSDictionary *env) {
  BKTransportHooks *hooks = BKTransportGet();
  if (hooks.stateWrite == nil) {
    return BKNotReady();
  }
  return hooks.stateWrite(env);
}
