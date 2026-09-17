// BKTransport.h
// Process-wide C/ObjC seam between the public BridgeKit module and BridgeKitNitro.
//
// The public module compiles BKTransport.m (the strong implementation).
// BridgeKitNitro only includes this header and calls the functions; it must not
// compile BKTransport.m, so a brownfield host can supply the one copy of the
// runtime while Nitro lives inside the packaged RN framework.

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^BKDictCallback)(NSDictionary *result);
typedef void (^BKInvokeCompletion)(NSDictionary *_Nullable ok, NSError *_Nullable err);
typedef void (^BKInvokeHandler)(NSDictionary *env, BKInvokeCompletion completion);
typedef void (^BKDictHandler)(NSDictionary *env);
typedef NSDictionary *_Nonnull (^BKSyncDictHandler)(NSDictionary *env);
typedef NSString *_Nonnull (^BKOpenStreamHandler)(
    NSDictionary *env,
    BKDictCallback onNext,
    BKDictCallback onEnd
);
typedef NSString *_Nonnull (^BKStateObserveHandler)(NSDictionary *env, BKDictCallback onChange);

typedef struct {
  BKDictCallback _Nullable invokeCompleteUnused;
} BKTransportReserved;

@interface BKTransportHooks : NSObject
@property (nonatomic, copy, nullable) void (^invoke)(NSDictionary *env, BKDictCallback complete);
@property (nonatomic, copy, nullable) BKSyncDictHandler invokeSync;
@property (nonatomic, copy, nullable) NSDictionary *_Nonnull (^connectDispatcher)(
    NSDictionary *epochInfo,
    BKInvokeHandler onInvoke,
    BKDictHandler onStreamOpen,
    BKDictHandler onStreamClose,
    BKDictHandler onStateWrite
);
@property (nonatomic, copy, nullable) BKOpenStreamHandler openStream;
@property (nonatomic, copy, nullable) void (^closeStream)(NSString *streamId);
@property (nonatomic, copy, nullable) void (^emitFromJs)(NSString *streamId, NSDictionary *value);
@property (nonatomic, copy, nullable) void (^endFromJs)(NSString *streamId, NSDictionary *end);
@property (nonatomic, copy, nullable) BKSyncDictHandler stateRead;
@property (nonatomic, copy, nullable) BKStateObserveHandler stateObserve;
@property (nonatomic, copy, nullable) void (^stateUnobserve)(NSString *obsId);
@property (nonatomic, copy, nullable) BKSyncDictHandler stateWrite;
@end

#ifdef __cplusplus
extern "C" {
#endif

void BKTransportInstall(BKTransportHooks *_Nullable hooks);
BKTransportHooks *_Nullable BKTransportGet(void);

void BKTransportInvoke(NSDictionary *env, BKDictCallback complete);
NSDictionary *BKTransportInvokeSync(NSDictionary *env);
NSDictionary *BKTransportConnectDispatcher(
    NSDictionary *epochInfo,
    BKInvokeHandler onInvoke,
    BKDictHandler onStreamOpen,
    BKDictHandler onStreamClose,
    BKDictHandler onStateWrite
);
NSString *BKTransportOpenStream(NSDictionary *env, BKDictCallback onNext, BKDictCallback onEnd);
void BKTransportCloseStream(NSString *streamId);
void BKTransportEmitFromJs(NSString *streamId, NSDictionary *value);
void BKTransportEndFromJs(NSString *streamId, NSDictionary *end);
NSDictionary *BKTransportStateRead(NSDictionary *env);
NSString *BKTransportStateObserve(NSDictionary *env, BKDictCallback onChange);
void BKTransportStateUnobserve(NSString *obsId);
NSDictionary *BKTransportStateWrite(NSDictionary *env);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
