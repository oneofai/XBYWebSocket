//
//  WebSocketManager.h
//  iPadPlayer
//
//  Created xby Kystar's Mac Book Pro on 2018/11/12.
//  Copyright © 2018 XBY. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <SRWebSocket.h>

#define XBYWebSocketShareManager [XBYWebSocketManager shareManager]

extern NSString * const kSocketConnectSuccessNotification;
extern NSString * const kSocketConnectFailNotification;
extern NSString * const kSocketCloseNotification;
extern NSString * const kSocketReconnectingNotification;
extern NSString * const kSocketReconnectFailNotification;
extern NSString * const kSocketReceiveMessageNotification;

@protocol XBYWebSocketManagerDelegate <NSObject>

- (void)XBYWebSocket:(SRWebSocket *)webSocket didReceiveMessage:(NSDictionary *)message;

@optional

- (void)XBYWebSocketDidOpen:(SRWebSocket *)webSocket;
- (void)XBYWebSocket:(SRWebSocket *)webSocket didFailWithError:(NSError *)error;
- (void)XBYWebSocket:(SRWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean;
- (void)XBYWebSocket:(SRWebSocket *)webSocket didReceivePong:(NSData *)pongPayload;

- (BOOL)XBYWebSocketShouldConvertTextFrameToString:(SRWebSocket *)webSocket;

@end

typedef NS_ENUM(NSInteger, XBYSocketReceiveType){
    XBYSocketReceiveTypeForMessage,
    XBYSocketReceiveTypeForPong
};

typedef NS_ENUM(NSInteger, XBYSocketCode){
    XBYSocketTimeoutCode                    = 504,  //正常定义，符合http 504超时定义
    XBYSocketCloseNormalCode                = 1101, //自定义，socket正常关闭
    XBYSocketCloseErrorCode                 , //自定义，socket异常关闭
    XBYSocketCloseToReconnectCode           , //自定义，socket重连之前关闭
    XBYSocketCloseReconnectFailCode         , //自定义，socket重连失败关闭
    XBYSocketEmptyCode                      , //自定义，socket被置空
    XBYSocketChangedCode                    , //自定义，存在两个以上socket实例（这种情况发生在重连逻辑，[socket close]和socket=nil未等待didclose代理回调完成，就调用新的[socket open]方法）
    XBYSocketReceiveWrongFormatDataCode     , //自定义，服务端返回数据没有返回唯一识别ID
    XBYSocketReceiveWrongIdentifyIdCode     , //自定义，服务端返回数据的唯一识别ID有误
    
};

typedef void(^XBYSocketDidConnectBlock)(void);

typedef void(^XBYSocketDidFailBlock)(NSError *error);

typedef void(^XBYSocketDidCloseBlock)(NSInteger code,NSString *reason,BOOL wasClean);

typedef void(^XBYSocketDidReceiveBlock)(NSDictionary *message, XBYSocketReceiveType type);

@interface XBYWebSocketManager : NSObject

@property (nonatomic, strong, readonly) SRWebSocket *webSocket;

@property (nonatomic, weak) id<XBYWebSocketManagerDelegate> delegate;

@property (nonatomic, copy, readonly) XBYSocketDidConnectBlock connectSuccessBlock;
@property (nonatomic, copy, readonly) XBYSocketDidFailBlock connectFailBlock;
@property (nonatomic, copy, readonly) XBYSocketDidCloseBlock closeBlock;
@property (nonatomic, assign, readonly) SRReadyState socketReadyState;

NS_ASSUME_NONNULL_BEGIN

/**
 * 发送心跳 和后台约定发送什么内容，不能为nil，SocketRocket可以为nil
 * 默认 pingInfo = @"ping"
 * pingInfo可以是NSString或者NSData类型
 * 只做了NSString的类型转换，不为NSString类型时，需要自己转成NSData类型
 */
@property (nonatomic, strong) id pingInfo;

/**
 * 手动开启心跳，默认为NO，在didOpen回调中自动启动心跳
 */
@property (nonatomic, assign) BOOL manualStartHeartBeat;

/**
 * 延迟多少秒启动heartBeat，默认为0
 */
@property (nonatomic, assign) NSTimeInterval startHeartBeatDelay;

/**
 * 重连次数，默认5次
 */
@property (nonatomic, assign) NSUInteger maxReconnectTimes;

/**
 * 超时时间
 * 默认是5秒
 * 如需更改，必须在"by_open:connect:failure:"方法调用之前设置，否则该方法超时不生效，其他send请求超时可生效
 * 该属性对"by_openWithRequest:connect:failure"无效
 */
@property (nonatomic, assign) NSTimeInterval timeoutInterval;

/**
 * ping不通的最大次数，默认3次，3次ping不通（6秒），则认为掉线
 */
@property (nonatomic, assign) NSUInteger maxPingTimes;

/**
 * ping发送间隔，默认2秒一次
 */
@property (nonatomic, assign) NSTimeInterval pingInterval;

/**
 * 错误域名，默认：com.xby.XBYSocket
 */
@property (nonatomic, strong) NSString *errorDomain;

/**
 * 第一次open socket失败是否需要启动重连，默认NO
 */
@property (nonatomic, assign) BOOL openFailNeedReconnect;

+ (instancetype)shareManager;

/**
 * 打开socket
 
 * @param urlStr urlString
 * @param connectBlock 打开连接成功回调
 * @param failureBlock 打开连接失败回调
 */
- (void)by_openWithUrlString:(NSString *)urlStr connect:(XBYSocketDidConnectBlock)connectBlock failure:(XBYSocketDidFailBlock)failureBlock;

/**
 * 打开socket
 
 * @param url url
 * @param connectBlock 打开连接成功回调
 * @param failureBlock 打开连接失败回调
 */
- (void)by_openWithUrl:(NSURL *)url connect:(XBYSocketDidConnectBlock)connectBlock failure:(XBYSocketDidFailBlock)failureBlock;

/**
 * 打开socket
 * timeoutInterval对这个方法不起作用，因为timeoutInterval是加在request的参数里面的
 * @param request requset可以包裹Url/CachePolicy/TimeoutInterval等信息
 * @param connectBlock 打开连接成功回调
 * @param failureBlock 打开连接失败回调
 */
- (void)by_openWithRequest:(NSURLRequest *)request connect:(XBYSocketDidConnectBlock)connectBlock failure:(XBYSocketDidFailBlock)failureBlock;

/**
 * 发送消息
 * @param dicData 消息Dictionary
 * @param receiveBlock 收到服务端数据返回回调
 * @param failureBlock 未收到服务端数据返回回调
 */
- (void)by_send:(NSDictionary *)dicData receive:(XBYSocketDidReceiveBlock)receiveBlock failure:(XBYSocketDidFailBlock)failureBlock;

/**
 手动启动HeartBeat，调用之后会将manualStartHeartBeat置为YES，再将manualStartHeartBeat更改回NO之前，都要自己手动启动

 @param delay 延迟
 */
- (void)by_manualStartHeartBeatAfterDelay:(NSTimeInterval)delay;

/**
 * 主动关闭socket
 * @param closeBlock 关闭回调
 */
- (void)by_closeSocketWithBlock:(XBYSocketDidCloseBlock)closeBlock;

NS_ASSUME_NONNULL_END

@end



