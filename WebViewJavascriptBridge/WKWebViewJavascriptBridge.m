//
//  WKWebViewJavascriptBridge.m
//
//  Created by @LokiMeyburg on 10/15/14.
//  Copyright (c) 2014 @LokiMeyburg. All rights reserved.
//


#import "WKWebViewJavascriptBridge.h"

#ifdef USE_CRASHLYTICS
    #import <Crashlytics/Answers.h>
#endif

#if defined(supportsWKWebKit)

NSString *const kNotificationWKWebViewBridgeDidDetectFatalError = @"wkWebViewBridge:fatalError";

@implementation WKWebViewJavascriptBridge {
    __weak WKWebView* _webView;
    __weak id<WKNavigationDelegate> _webViewDelegate;
    long _uniqueId;
    WebViewJavascriptBridgeBase *_base;
    int _navigationCount;
    NSNumber *_buildNumber;
}

/* API
 *****/

+ (void)enableLogging { [WebViewJavascriptBridgeBase enableLogging]; }

+ (instancetype)bridgeForWebView:(WKWebView*)webView {
    WKWebViewJavascriptBridge* bridge = [[self alloc] init];
    [bridge _setupInstance:webView];
    [bridge reset];
    return bridge;
}

- (void)send:(id)data {
    [self send:data responseCallback:nil];
}

- (void)send:(id)data responseCallback:(WVJBResponseCallback)responseCallback {
    [_base sendData:data responseCallback:responseCallback handlerName:nil];
}

- (void)callHandler:(NSString *)handlerName {
    [self callHandler:handlerName data:nil responseCallback:nil];
}

- (void)callHandler:(NSString *)handlerName data:(id)data {
    [self callHandler:handlerName data:data responseCallback:nil];
}

- (void)callHandler:(NSString *)handlerName data:(id)data responseCallback:(WVJBResponseCallback)responseCallback {
    [_base sendData:data responseCallback:responseCallback handlerName:handlerName];
}

- (void)registerHandler:(NSString *)handlerName handler:(WVJBHandler)handler {
    _base.messageHandlers[handlerName] = [handler copy];
}

- (void)reset {
    [_base reset];
}

- (void)setWebViewDelegate:(id<WKNavigationDelegate>)webViewDelegate {
    _webViewDelegate = webViewDelegate;
}

- (void)disableJavscriptAlertBoxSafetyTimeout {
    [_base disableJavscriptAlertBoxSafetyTimeout];
}

/* Internals
 ***********/

- (void)dealloc {
    _base = nil;
    _webView = nil;
    _webViewDelegate = nil;
    _webView.navigationDelegate = nil;
}


/* WKWebView Specific Internals
 ******************************/

- (void) _setupInstance:(WKWebView*)webView {
    _webView = webView;
    _webView.navigationDelegate = self;
    _base = [[WebViewJavascriptBridgeBase alloc] init];
    _base.delegate = self;

    _buildNumber = [[NSBundle mainBundle] infoDictionary][@"CFBundleVersion"];
}


- (void)WKFlushMessageQueue {
    NSLog(@"WKFlushMessageQueue");
    NSString *js = [_base webViewJavascriptFetchQueyCommand];
    [_webView evaluateJavaScript:js completionHandler:^(NSString* result, NSError* error) {
        [_base flushMessageQueue:result];
        if (error) {
            GCNLogError(@"Bridge-Eval-Error L:103!!!\nMethod: WKFlushMessageQueue\nResult: %@\nError: %@\nJS: %@",
                        result ?: @"nil result",
                        error.localizedDescription ?: @"nil error",
                        js ?: @"nil js");
            [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationWKWebViewBridgeDidDetectFatalError
                                                                object:nil];

#ifdef USE_CRASHLYTICS
            [Answers logCustomEventWithName:@"bridge-eval-error"
                           customAttributes:@{@"method:": @"WKFlushMessageQueue",
                                              @"result": result ?: @"nil result",
                                              @"error": error.localizedDescription ?: @"nil error",
                                              @"js": js ?: @"nil js",
                                              @"build": _buildNumber}];
#endif
        }
    }];
}

- (void)setJsVersion:(NSString *)jsVersion {
    _jsVersion = jsVersion;
    _navigationCount = 0;
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(null_unspecified WKNavigation *)navigation {
    GCNLogError(@"DID COMMIT NAVIGATION: URL: %@, %@ %d", [webView.URL absoluteString], navigation, _navigationCount);
    if (_navigationCount) {
#ifdef USE_CRASHLYTICS
        [Answers logCustomEventWithName:@"bridge-did-commit-navigation"
                       customAttributes:@{@"webview.URL": [webView.URL absoluteString] ?: @"nil url",
                                          @"navigation": [navigation description] ?: @"nil navigation",
                                          @"build": _buildNumber}];
#endif
    }
    _navigationCount++;
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    GCNLogError(@"CONTENT DID TERMINATE %@", [webView.URL absoluteString]);
    [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationWKWebViewBridgeDidDetectFatalError
                                                        object:nil];
#ifdef USE_CRASHLYTICS
    [Answers logCustomEventWithName:@"bridge-did-terminate"
                   customAttributes:@{@"webview.URL": [webView.URL absoluteString] ?: @"nil url",
                                      @"build": _buildNumber}];
#endif
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    if (webView != _webView) { return; }
    
    __strong typeof(_webViewDelegate) strongDelegate = _webViewDelegate;
    if (strongDelegate && [strongDelegate respondsToSelector:@selector(webView:didFinishNavigation:)]) {
        [strongDelegate webView:webView didFinishNavigation:navigation];
    }
}

- (void)webView:(WKWebView *)webView didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler
{
    if (webView != _webView) { return; }

    __strong typeof(_webViewDelegate) strongDelegate = _webViewDelegate;
    if (strongDelegate && [strongDelegate respondsToSelector:@selector(webView:didReceiveAuthenticationChallenge:completionHandler:)]) {
        [strongDelegate webView:webView didReceiveAuthenticationChallenge:challenge completionHandler:completionHandler];
    }
}

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    if (webView != _webView) { return; }
    NSURL *url = navigationAction.request.URL;
    __strong typeof(_webViewDelegate) strongDelegate = _webViewDelegate;

    if ([_base isCorrectProcotocolScheme:url]) {
        if ([_base isBridgeLoadedURL:url]) {
            [_base injectJavascriptFile];
        } else if ([_base isQueueMessageURL:url]) {
            [self WKFlushMessageQueue];
        } else {
            [_base logUnkownMessage:url];
        }
        decisionHandler(WKNavigationActionPolicyCancel);
    }
    
    if (strongDelegate && [strongDelegate respondsToSelector:@selector(webView:decidePolicyForNavigationAction:decisionHandler:)]) {
        [_webViewDelegate webView:webView decidePolicyForNavigationAction:navigationAction decisionHandler:decisionHandler];
    } else {
        decisionHandler(WKNavigationActionPolicyAllow);
    }
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    if (webView != _webView) { return; }
    
    __strong typeof(_webViewDelegate) strongDelegate = _webViewDelegate;
    if (strongDelegate && [strongDelegate respondsToSelector:@selector(webView:didStartProvisionalNavigation:)]) {
        [strongDelegate webView:webView didStartProvisionalNavigation:navigation];
    }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    decisionHandler(WKNavigationResponsePolicyAllow);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(null_unspecified WKNavigation *)navigation
      withError:(NSError *)error {
    GCNLogError(@"FAILED provisional navigation!!!\nError: %@\nURL: %@",
                error.localizedDescription ?: @"nil error",
                [webView.URL absoluteString] ?: @"nil url");
    [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationWKWebViewBridgeDidDetectFatalError
                                                        object:nil];

#ifdef USE_CRASHLYTICS
    [Answers logCustomEventWithName:@"failed-provisional-navigation"
                   customAttributes:@{@"error": error.localizedDescription ?: @"nil error",
                                      @"webview.URL": [webView.URL absoluteString] ?: @"nil url",
                                      @"build": _buildNumber}];
#endif
}

- (void)webView:(WKWebView *)webView
didReceiveServerRedirectForProvisionalNavigation:(null_unspecified WKNavigation *)navigation {
    GCNLogError(@"REDIRECT provisional navigation!!!\nURL: %@",
                [webView.URL absoluteString] ?: @"nil url");

#ifdef USE_CRASHLYTICS
    [Answers logCustomEventWithName:@"redirect-provisional-navigation"
                   customAttributes:@{@"webview.URL": [webView.URL absoluteString] ?: @"nil url",
                                      @"build": _buildNumber}];
#endif
}

- (void)webView:(WKWebView *)webView
didFailNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
    if (webView != _webView) { return; }
    
    __strong typeof(_webViewDelegate) strongDelegate = _webViewDelegate;
    if (strongDelegate && [strongDelegate respondsToSelector:@selector(webView:didFailNavigation:withError:)]) {
        [strongDelegate webView:webView didFailNavigation:navigation withError:error];
    }
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (webView != _webView) { return; }
    
    __strong typeof(_webViewDelegate) strongDelegate = _webViewDelegate;
    if (strongDelegate && [strongDelegate respondsToSelector:@selector(webView:didFailProvisionalNavigation:withError:)]) {
        [strongDelegate webView:webView didFailProvisionalNavigation:navigation withError:error];
    }
}

- (NSString*) _evaluateJavascript:(NSString*)javascriptCommand
{
    [_webView evaluateJavaScript:javascriptCommand completionHandler:^(NSString *result, NSError *error) {
        if (error) {
            GCNLogError(@"Bridge-Eval-Error L:228!!!\nMethod: _evaluateJavascript\nResult: %@\nError: %@\nJS: %@",
                        result ?: @"nil result",
                        error.localizedDescription ?: @"nil error",
                        javascriptCommand ?: @"nil js");
            [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationWKWebViewBridgeDidDetectFatalError
                                                                object:nil];

#ifdef USE_CRASHLYTICS
            [Answers logCustomEventWithName:@"bridge-eval-error"
                           customAttributes:@{@"method:": @"_evaluateJavascript",
                                              @"result": result ?: @"nil result",
                                              @"error": error.localizedDescription ?: @"nil error",
                                              @"js": javascriptCommand ?: @"nil js",
                                              @"build": _buildNumber}];
#endif
        }
    }];
    return NULL;
}

@end


#endif
