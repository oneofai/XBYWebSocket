//
//  WebSocketManager.m
//  iPadPlayer
//
//  Created xby Kystar's Mac Book Pro on 2018/11/12.
//  Copyright © 2018 XBY. All rights reserved.
//

#import "XBYWebSocketManager.h"

#define dispatch_main_async_safe(block)\
if ([NSThread isMainThread]) {\
block();\
} else {\
dispatch_async(dispatch_get_main_queue(), block);\
}

#define WeakSelf __weak typeof(self) weakSelf = self;

NSString * const kSocketConnectSuccessNotification = @"kSocketConnectSuccessNotification";
NSString * const kSocketConnectFailNotification = @"kSocketConnectFailNotification";
NSString * const kSocketCloseNotification = @"kSocketCloseNotification";
NSString * const kSocketReconnectingNotification = @"kSocketReconnectingNotification";
NSString * const kSocketReconnectFailNotification = @"kSocketReconnectFailNotification";
NSString * const kSocketReceiveMessageNotification = @"kSocketReceiveMessageNotification";

typedef NS_ENUM(NSInteger, XBYSocketOpenType){
    XBYSocketOpenByUrlString,
    XBYSocketOpenByUrl,
    XBYSocketOpenByRequest,
};

@interface XBYWebSocketManager ()<SRWebSocketDelegate>

@property (nonatomic, strong, readwrite) SRWebSocket *webSocket;

@property (nonatomic, copy, readwrite) XBYSocketDidConnectBlock connectSuccessBlock;
@property (nonatomic, copy, readwrite) XBYSocketDidFailBlock connectFailBlock;
@property (nonatomic, copy, readwrite) XBYSocketDidCloseBlock closeBlock;

@property (nonatomic, assign) XBYSocketOpenType openType;

/**
 * send 命令维护表
 * 格式：
 * @{identificationID : @{kIdentificationIDKey : id, kReceiveSuccessBlockKey : obj, kReceiveFailBlockKey : obj}}
 */
@property (nonatomic, strong) NSMutableDictionary <NSString *, id> *allSendRequestDic;

@property (nonatomic, strong) NSTimer *heartBeatTimer;

@property (nonatomic, assign) NSUInteger tryPingTimes; //尝试ping次数

@property (nonatomic, assign) NSUInteger tryReconnectTimes; //尝试重连次数

@property (nonatomic, strong) NSString *openUrlString;
@property (nonatomic, strong) NSURL *openUrl;
@property (nonatomic, strong) NSURLRequest *openRequest;

@end

@implementation XBYWebSocketManager

static NSString * const kReceiveSuccessBlockKey = @"kReceiveSuccessBlockKey";
static NSString * const kReceiveFailBlockKey = @"kReceiveFailBlockKey";
static NSString * const kSendTimerKey = @"kSendTimerKey";
static NSString * const kIdentificationIDKey = @"identificationID";

static XBYWebSocketManager *instance;

+ (instancetype)shareManager {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
        
    });
    return instance;
}

+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [super allocWithZone:zone];
    });
    return instance;
}

- (id)copyWithZone:(NSZone *)zone {
    return instance;
}

-(id)mutableCopyWithZone:(NSZone *)zone{
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _timeoutInterval = 5;                   //默认超时时间5秒
        _maxReconnectTimes = 5;                 //默认最大重连次数5次
        _pingInfo = @"ping";                    //默认sendPing的内容
        _errorDomain = @"com.xby.XBYSocket";
        _maxPingTimes = 3;                      //ping不通的最大次数，默认3次，3次ping不通（6秒），则认为掉线
        _pingInterval = 2;                      //ping发送时间，默认2秒一次
        _manualStartHeartBeat = NO;
        _startHeartBeatDelay = 0;
        _allSendRequestDic = @{}.mutableCopy;
        _openFailNeedReconnect = NO;
    }
    return self;
}

#pragma mark - ---- Public Method
- (void)by_openWithUrlString:(NSString *)urlStr connect:(XBYSocketDidConnectBlock)connectBlock failure:(XBYSocketDidFailBlock)failureBlock {
    NSAssert(urlStr.length>0, @"Url String不能为空!");
    self.openUrlString = urlStr;
    self.openType = XBYSocketOpenByUrlString;

    NSURLRequest * request = [NSURLRequest requestWithURL:[NSURL URLWithString:urlStr] cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:_timeoutInterval];
    [self by_openWithRequest:request connect:connectBlock failure:failureBlock];
}

- (void)by_openWithUrl:(NSURL *)url connect:(XBYSocketDidConnectBlock)connectBlock failure:(XBYSocketDidFailBlock)failureBlock {
    NSAssert(url != nil, @"Url不能为空!");
    self.openUrl = url;
    self.openType = XBYSocketOpenByUrl;
    
    NSURLRequest * request = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:_timeoutInterval];
    [self by_openWithRequest:request connect:connectBlock failure:failureBlock];
}

- (void)by_openWithRequest:(NSURLRequest *)request connect:(XBYSocketDidConnectBlock)connectBlock failure:(XBYSocketDidFailBlock)failureBlock {
    NSAssert(request != nil , @"Request参数不能为空!");
    self.openRequest = request;
    self.openType = XBYSocketOpenByRequest;
    
    self.connectSuccessBlock = connectBlock;
    self.connectFailBlock = failureBlock;
    
    self.webSocket = [[SRWebSocket alloc] initWithURLRequest:request];
    self.webSocket.delegate = self;
    
    [self.webSocket open];
}

- (void)by_closeSocketWithBlock:(XBYSocketDidCloseBlock)closeBlock {
    self.closeBlock = closeBlock;
    [self p_closeSocketWithCode:XBYSocketCloseNormalCode reason:@"Socket close normal!"];
}

- (void)by_manualStartHeartBeatAfterDelay:(NSTimeInterval)delay {
    NSAssert(delay>=0, @"Error: 延迟不能小于0");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self p_initHeartBeat];
    });
}

- (void)by_send:(NSDictionary *)dicData receive:(XBYSocketDidReceiveBlock)receiveBlock failure:(XBYSocketDidFailBlock)failureBlock {
    if (dicData == nil || dicData.allKeys.count<1) {
        return;
    }
    
    NSMutableDictionary *mutDic = dicData.mutableCopy;
    NSString *identificationID = [NSString stringWithFormat:@"%@%@",[self p_currentTimeString],[self p_randomNumbers]];
    mutDic[kIdentificationIDKey] = identificationID;
    
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:mutDic options:NSJSONWritingPrettyPrinted error:&error];
    
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    
    NSMutableDictionary *callBackDic = @{}.mutableCopy;
    if (receiveBlock) {
        [callBackDic setObject:receiveBlock forKey:kReceiveSuccessBlockKey];
    }
    if (failureBlock) {
        [callBackDic setObject:failureBlock forKey:kReceiveFailBlockKey];
    }

    // 创建NSTimer对象
    NSTimer *timer = [NSTimer timerWithTimeInterval:_timeoutInterval target:self selector:@selector(timerAction:) userInfo:identificationID repeats:NO];
    // 加入RunLoop中
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    
    [callBackDic setObject:timer forKey:kSendTimerKey];
    
    [self.allSendRequestDic setObject:callBackDic forKey:identificationID];
    
    [self p_send:jsonString withId:identificationID];
}

#pragma mark - ---- Private Method p_开头为私有方法
- (void)p_send:(id)data withId:(NSString *)idStr {
    NSDictionary *sendRequestDic = [self.allSendRequestDic objectForKey:idStr];
    
    if (self.webSocket != nil) {
        switch (self.socketReadyState) {
            case SR_OPEN:{
                [self.webSocket send:data];    // 发送数据
            }
                break;
            case SR_CLOSED:
            case SR_CLOSING: {
                if (self.closeBlock) {
                    self.closeBlock(XBYSocketCloseErrorCode, @"Unkonw error cause socket close!", 0);
                }
                [[NSNotificationCenter defaultCenter] postNotificationName:kSocketCloseNotification object:nil];
            }
                break;
            case SR_CONNECTING: {
                
            }
                break;
            default:{
                return;
            }
        }
    } else {
        NSTimer *timer = [sendRequestDic objectForKey:kSendTimerKey];
        [timer invalidate];
        timer = nil;
        XBYSocketDidFailBlock failBlock = [sendRequestDic objectForKey:kReceiveFailBlockKey];
        if (failBlock) {
            failBlock([NSError errorWithDomain:_errorDomain code:XBYSocketEmptyCode userInfo:@{NSLocalizedDescriptionKey: @"Send message fail by socket was clean up"}]);
        }
        [self.allSendRequestDic removeObjectForKey:idStr];
    }
}

/**
 * 不主动调用这个方法，统一在didClose回调中调用，避免close未执行完毕，又open生成了新的socket实例
 */
- (void)p_reconnectSocket {
    
    self.tryReconnectTimes ++;
    if (_tryReconnectTimes >= _maxReconnectTimes) {
        //重连失败
        [self p_closeSocketWithCode:XBYSocketCloseReconnectFailCode reason:@"Reconnect socket fail"];
        [[NSNotificationCenter defaultCenter] postNotificationName:kSocketReconnectFailNotification object:nil];
        return;
    }

    switch (self.openType) {
        case XBYSocketOpenByUrlString: {
            [self by_openWithUrlString:self.openUrlString connect:self.connectSuccessBlock failure:self.connectFailBlock];
        }
            break;
        case XBYSocketOpenByUrl: {
            [self by_openWithUrl:self.openUrl connect:self.connectSuccessBlock failure:self.connectFailBlock];
        }
            break;
        case XBYSocketOpenByRequest: {
            [self by_openWithRequest:self.openRequest connect:self.connectSuccessBlock failure:self.connectFailBlock];
        }
            break;
        default:
            break;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:kSocketReconnectingNotification object:nil];
    
}

- (void)p_closeSocket {
    if (self.webSocket) {
        [self.webSocket close];
        self.webSocket = nil;
    }
}

- (void)p_closeSocketWithCode:(NSInteger)code reason:(NSString *)reason {
    if (self.webSocket) {
        [self.webSocket closeWithCode:code reason:reason];
        self.webSocket = nil;
    }
}

- (void)p_closeSocketAndDestoryHeartBeat {
    [self p_closeSocket];
    [self p_destoryHeartBeat];
}

#pragma mark ---- Heart Beat
//初始化心跳
- (void)p_initHeartBeat {
    WeakSelf
    dispatch_main_async_safe(^{
        [self p_destoryHeartBeat];
        weakSelf.heartBeatTimer = [NSTimer timerWithTimeInterval:weakSelf.pingInterval target:self selector:@selector(p_sendHeartBeat) userInfo:nil repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:weakSelf.heartBeatTimer forMode:NSRunLoopCommonModes];
    })
}

//取消心跳
- (void)p_destoryHeartBeat {
    WeakSelf;
    dispatch_main_async_safe(^{
        if (weakSelf.heartBeatTimer) {
            [weakSelf.heartBeatTimer invalidate];
            weakSelf.heartBeatTimer = nil;
        }
    })
}

-(void)p_sendHeartBeat{
    
    [self p_ping];
}

//pingPong
- (void)p_ping{
    
    if (self.maxPingTimes >1) { //最大ping不通次数大于1时要先做++操作，不然次数对不上
        self.tryPingTimes ++;
    }
    if (self.tryPingTimes >=  self.maxPingTimes) {
        [self p_closeSocketWithCode:XBYSocketCloseToReconnectCode reason:@"Socket need reconnect"];
    } else {
        [self p_socketSendPingData];
    }
    if (self.maxPingTimes == 1) {   //最大ping不通次数等于1时要后做++操作，不然每次都走重连逻辑
        self.tryPingTimes ++;
    }
    
}

- (void)p_socketSendPingData {
    if (self.webSocket.readyState == SR_OPEN) {
        //和服务端约定好发送什么作为心跳标识，尽可能的减小心跳包大小
        NSData *data;
        
        if([_pingInfo isKindOfClass:[NSString class]]) {
            NSString *str = _pingInfo;
            data =[str dataUsingEncoding:NSUTF8StringEncoding];
        } else {
            data = _pingInfo;
        }
        
        [self.webSocket sendPing:data];
    }
}

#pragma mark ---- Tools Method
- (NSString *)p_currentTimeString {
    NSDateFormatter *df = [NSDateFormatter new];
    [df setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    return [df stringFromDate:[NSDate date]];
}

- (NSString *)p_randomNumbers {
    NSString *string = @"";
    for (int i=0; i<5; i++) {
        string = [string stringByAppendingString:[NSString stringWithFormat:@"%d",(arc4random() % 10)]];
    }
    return string;
}

-(void)p_checkTimeoutMsg:(NSString *)identificationID{
    
    if ([self.allSendRequestDic.allKeys containsObject:identificationID]) {
        NSMutableDictionary * callBackDic = [self.allSendRequestDic objectForKey:identificationID];
        
        XBYSocketDidFailBlock failure = callBackDic[kReceiveFailBlockKey];
        if (failure) {
            failure([NSError errorWithDomain:_errorDomain code:XBYSocketTimeoutCode userInfo:@{NSLocalizedDescriptionKey: @"Timeout Connecting to Server"}]);
        }
        
        [self.allSendRequestDic removeObjectForKey:identificationID];
    }
}

#pragma mark - ---- Timer Target Action
- (void)timerAction:(NSTimer *)timer {
    NSString *identificationID = timer.userInfo;
    [self p_checkTimeoutMsg:identificationID];
    
    [timer invalidate];
    timer = nil;
}

#pragma mark - ---- SRWebSocketDelegate
// message will either be an NSString if the server is using text
// or NSData if the server is using binary.
- (void)webSocket:(SRWebSocket *)webSocket didReceiveMessage:(id)message {
    NSError *error = nil;
    NSData *jsonData = [message dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *parseDataDic = [NSJSONSerialization JSONObjectWithData:jsonData
                                                                 options:NSJSONReadingMutableContainers
                                                                   error:&error];
    NSString *identificationID = @"";
    if (![parseDataDic.allKeys containsObject:kIdentificationIDKey]) {
        NSLog(@"%@",[NSError errorWithDomain:_errorDomain code:XBYSocketReceiveWrongFormatDataCode userInfo:@{NSLocalizedDescriptionKey: @"Socket receive wrong format data"}]);
        return;
    }
    
    identificationID = parseDataDic[kIdentificationIDKey];
    if(![self.allSendRequestDic.allKeys containsObject:identificationID]) {
        NSLog(@"%@",[NSError errorWithDomain:_errorDomain code:XBYSocketReceiveWrongIdentifyIdCode userInfo:@{NSLocalizedDescriptionKey: @"Received wrong identify id!"}]);
        return;
    }
    NSDictionary *sendRequestDic = self.allSendRequestDic[identificationID];
    
    if (webSocket == self.webSocket) {
        XBYSocketDidReceiveBlock receiveBlock = sendRequestDic[kReceiveSuccessBlockKey];
        if (receiveBlock) {
            receiveBlock(parseDataDic, XBYSocketReceiveTypeForMessage);
        }
        
        if([self.delegate respondsToSelector:@selector(XBYWebSocket:didReceiveMessage:)]) {
            [self.delegate XBYWebSocket:webSocket didReceiveMessage:parseDataDic];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:kSocketReceiveMessageNotification object:parseDataDic];
    } else {
        XBYSocketDidFailBlock failBlock = sendRequestDic[kReceiveFailBlockKey];
        if (failBlock) {
            failBlock([NSError errorWithDomain:_errorDomain code:XBYSocketChangedCode userInfo:@{NSLocalizedDescriptionKey: @"Socket did changed!"}]);
        }
    }
    NSTimer *timer = [sendRequestDic objectForKey:kSendTimerKey];
    [timer invalidate];
    timer = nil;
    [self.allSendRequestDic removeObjectForKey:identificationID];
}

- (void)webSocketDidOpen:(SRWebSocket *)webSocket {
    // 开启成功后重置重连计数器
    _tryReconnectTimes = 0;
    _tryPingTimes = 0;
    
    if (!_manualStartHeartBeat) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_startHeartBeatDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self p_initHeartBeat];
        });
    }
    
    if (self.connectSuccessBlock) {
        self.connectSuccessBlock();
    }
    if ([self.delegate respondsToSelector:@selector(XBYWebSocketDidOpen:)]) {
        [self.delegate XBYWebSocketDidOpen:webSocket];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:kSocketConnectSuccessNotification object:nil];
}

- (void)webSocket:(SRWebSocket *)webSocket didFailWithError:(NSError *)error {
    
    if (self.connectFailBlock) {
        self.connectFailBlock(error);
    }
    
    if ([self.delegate respondsToSelector:@selector(XBYWebSocket:didFailWithError:)]) {
        [self.delegate XBYWebSocket:webSocket didFailWithError:error];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:kSocketConnectFailNotification object:nil userInfo:@{@"error":error}];
    
    // 重连
    if (self.openFailNeedReconnect) {
        [self p_reconnectSocket];
    }

}

- (void)webSocket:(SRWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean {
    if ([self.delegate respondsToSelector:@selector(XBYWebSocket:didCloseWithCode:reason:wasClean:)]) {
        [self.delegate XBYWebSocket:webSocket didCloseWithCode:code reason:reason wasClean:wasClean];
    }
    switch (code) {
        case XBYSocketCloseToReconnectCode: {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_tryReconnectTimes * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self p_reconnectSocket];
            });
        }
            break;
        default: {
            if (self.closeBlock) {
                self.closeBlock(code, reason, wasClean);
            }
            [[NSNotificationCenter defaultCenter] postNotificationName:kSocketCloseNotification object:nil userInfo:@{@"code":@(code),@"reason":reason,@"wasClean":@(wasClean)}];
        }
            break;
    }

}

- (void)webSocket:(SRWebSocket *)webSocket didReceivePong:(NSData *)pongPayload {
    self.tryPingTimes = 0;
    if ([self.delegate respondsToSelector:@selector(XBYWebSocket:didReceivePong:)]) {
        [self.delegate XBYWebSocket:webSocket didReceivePong:pongPayload];
    }
    
}

// Return YES to convert messages sent as Text to an NSString. Return NO to skip NSData -> NSString conversion for Text messages. Defaults to YES.
- (BOOL)webSocketShouldConvertTextFrameToString:(SRWebSocket *)webSocket {
    if ([self.delegate respondsToSelector:@selector(XBYWebSocketShouldConvertTextFrameToString:)]) {
        return [self.delegate XBYWebSocketShouldConvertTextFrameToString:webSocket];
    }
    return YES;
}

- (void)dealloc{
    // Close WebSocket
    [self p_closeSocket];
}

#pragma mark - ---- Setter
- (void)setMaxReconnectTimes:(NSUInteger)maxReconnectTimes {
    NSAssert(maxReconnectTimes > 0, @"Error: 最大重连次数必须大于0");
    _maxReconnectTimes = maxReconnectTimes;
}

- (void)setTimeoutInterval:(NSTimeInterval)timeoutInterval {
    NSAssert(timeoutInterval>0, @"Error: 超时时间必须大于0");
    _timeoutInterval = timeoutInterval;
}

- (void)setMaxPingTimes:(NSUInteger)maxPingTimes {
    NSAssert(maxPingTimes>0, @"Error: 最大ping次数必须大于0");
    _maxPingTimes = maxPingTimes;
}

- (void)setPingInterval:(NSTimeInterval)pingInterval {
    NSAssert(pingInterval>0, @"Error: ping时间间隔必须大于0");
}

- (void)setPingInfo:(id)pingInfo {
    NSAssert([pingInfo isKindOfClass:[NSString class]] || [pingInfo isKindOfClass:[NSData class]], @"Error: ping消息需要是NSString或者NSData类型");
}

- (void)setErrorDomain:(NSString *)errorDomain {
    NSAssert(errorDomain.length>0, @"Error: 错误域名不能为空!");
    _errorDomain = errorDomain;
}

#pragma mark - ---- Getter
- (SRReadyState)socketReadyState {
    return self.webSocket.readyState;
}

@end
