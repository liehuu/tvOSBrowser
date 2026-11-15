#import "BrowserWebView.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const kBrowserWebViewClassName = @"WKWebView";
static NSString * const kBrowserWebViewConfigurationClassName = @"WKWebViewConfiguration";
static NSString * const kBrowserWebsiteDataStoreClassName = @"WKWebsiteDataStore";
static NSString * const kBrowserUserContentControllerClassName = @"WKUserContentController";
static NSString * const kBrowserUserScriptClassName = @"WKUserScript";

static void BrowserEnsureWebKitRuntimeLoaded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (NSClassFromString(kBrowserWebViewClassName) != Nil) {
            return;
        }

        NSArray<NSString *> *candidatePaths = @[
            @"/System/Library/Frameworks/WebKit.framework/WebKit",
            @"/System/Library/PrivateFrameworks/WebKit.framework/WebKit",
            @"/System/Library/StagedFrameworks/Safari/WebKit.framework/WebKit",
        ];

        for (NSString *candidatePath in candidatePaths) {
            if (dlopen(candidatePath.UTF8String, RTLD_NOW | RTLD_GLOBAL) != NULL && NSClassFromString(kBrowserWebViewClassName) != Nil) {
                break;
            }
        }
    });
}

static void BrowserPumpRunLoopUntil(BOOL *done) {
    while (!*done) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
    }
}

static NSString *BrowserStringFromJavaScriptResult(id result) {
    if (result == nil || result == [NSNull null]) {
        return nil;
    }
    if ([result isKindOfClass:[NSString class]]) {
        return result;
    }
    if ([result respondsToSelector:@selector(stringValue)]) {
        return [result stringValue];
    }
    return [result description];
}

static BOOL BrowserSelectorNameMatchesMediaFilter(NSString *selectorName) {
    static NSArray<NSString *> *keywords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[
            @"mediasource",
            @"managedmediasource",
            @"sourcebuffer",
            @"media",
            @"video",
            @"inline",
            @"autoplay",
            @"fullscreen",
            @"pictureinpicture",
            @"airplay",
            @"webm",
            @"vp9",
            @"av1",
            @"hls",
            @"mse",
            @"codec",
        ];
    });

    NSString *lowercaseSelectorName = selectorName.lowercaseString;
    for (NSString *keyword in keywords) {
        if ([lowercaseSelectorName containsString:keyword]) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *BrowserFilteredSelectorNamesForClass(Class klass) {
    if (klass == Nil) {
        return @[];
    }

    NSMutableOrderedSet<NSString *> *selectorNames = [NSMutableOrderedSet orderedSet];
    for (Class currentClass = klass; currentClass != Nil && currentClass != [NSObject class]; currentClass = class_getSuperclass(currentClass)) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(currentClass, &methodCount);
        for (unsigned int methodIndex = 0; methodIndex < methodCount; methodIndex += 1) {
            SEL selector = method_getName(methods[methodIndex]);
            NSString *selectorName = NSStringFromSelector(selector);
            if (selectorName.length > 0 && BrowserSelectorNameMatchesMediaFilter(selectorName)) {
                [selectorNames addObject:selectorName];
            }
        }
        free(methods);
    }

    return [selectorNames.array sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

static NSString *BrowserGetterNameFromSetterName(NSString *setterName) {
    if (![setterName hasPrefix:@"set"] || ![setterName hasSuffix:@":"] || setterName.length <= 4) {
        return nil;
    }

    NSString *propertyStem = [setterName substringWithRange:NSMakeRange(3, setterName.length - 4)];
    if (propertyStem.length == 0) {
        return nil;
    }

    NSString *firstCharacter = [[propertyStem substringToIndex:1] lowercaseString];
    if (propertyStem.length == 1) {
        return firstCharacter;
    }

    return [firstCharacter stringByAppendingString:[propertyStem substringFromIndex:1]];
}

static NSString *BrowserBooleanValueDescriptionForObjectAndSelector(id object, NSString *selectorName) {
    if (object == nil || selectorName.length == 0) {
        return nil;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return nil;
    }

    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature == nil || signature.numberOfArguments != 2) {
        return nil;
    }

    const char *returnType = signature.methodReturnType;
    if (returnType == NULL) {
        return nil;
    }

    if (returnType[0] != 'B' && returnType[0] != 'c') {
        return nil;
    }

    BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    return value ? @"YES" : @"NO";
}

static id BrowserObjectResultForGetter(id object, NSString *selectorName) {
    if (object == nil || selectorName.length == 0) {
        return nil;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return nil;
    }

    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature == nil || signature.numberOfArguments != 2) {
        return nil;
    }

    const char *returnType = signature.methodReturnType;
    if (returnType == NULL || returnType[0] != '@') {
        return nil;
    }

    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *BrowserPreviewString(NSString *string, NSUInteger maxLength) {
    if (string.length <= maxLength) {
        return string;
    }
    return [[string substringToIndex:maxLength] stringByAppendingString:@"\n…"];
}

static NSString *BrowserStringValueForKnownSelectors(id object, NSArray<NSString *> *selectorNames) {
    for (NSString *selectorName in selectorNames) {
        id result = BrowserObjectResultForGetter(object, selectorName);
        if (result == nil || result == [NSNull null]) {
            continue;
        }
        NSString *stringResult = nil;
        if ([result isKindOfClass:[NSString class]]) {
            stringResult = result;
        } else if ([result respondsToSelector:@selector(stringValue)]) {
            stringResult = [result stringValue];
        } else {
            stringResult = [result description];
        }

        if (stringResult.length > 0) {
            return stringResult;
        }
    }
    return nil;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *BrowserFeatureEntriesForPreferences(id preferences) {
    if (preferences == nil) {
        return @[];
    }

    NSArray<NSString *> *collectionSelectors = @[
        @"_experimentalFeatures",
        @"_internalDebugFeatures",
        @"_features",
    ];

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *entries = [NSMutableArray array];
    for (NSString *collectionSelectorName in collectionSelectors) {
        id collection = BrowserObjectResultForGetter(preferences, collectionSelectorName);
        if (![collection conformsToProtocol:@protocol(NSFastEnumeration)]) {
            continue;
        }

        for (id feature in collection) {
            NSString *name = BrowserStringValueForKnownSelectors(feature, @[@"name", @"key", @"identifier", @"title", @"details"]);
            if (name.length == 0) {
                continue;
            }

            NSString *lowercaseName = name.lowercaseString;
            if (![lowercaseName containsString:@"media"] &&
                ![lowercaseName containsString:@"source"] &&
                ![lowercaseName containsString:@"vp9"] &&
                ![lowercaseName containsString:@"av1"] &&
                ![lowercaseName containsString:@"webm"] &&
                ![lowercaseName containsString:@"video"] &&
                ![lowercaseName containsString:@"mse"] &&
                ![lowercaseName containsString:@"managed"]) {
                continue;
            }

            NSString *enabledValue = BrowserBooleanValueDescriptionForObjectAndSelector(feature, @"enabled");
            if (enabledValue == nil) {
                enabledValue = BrowserBooleanValueDescriptionForObjectAndSelector(feature, @"isEnabled");
            }
            if (enabledValue == nil) {
                enabledValue = @"unknown";
            }

            NSString *key = BrowserStringValueForKnownSelectors(feature, @[@"key", @"identifier"]);
            NSString *source = [collectionSelectorName stringByReplacingOccurrencesOfString:@"_" withString:@""];
            [entries addObject:@{
                @"source": source ?: @"features",
                @"name": name,
                @"enabled": enabledValue,
                @"key": key ?: @"",
            }];
        }
    }

    return entries;
}

static void BrowserSetBooleanSelectorIfAvailable(id object, NSString *selectorName, BOOL value) {
    if (object == nil || selectorName.length == 0) {
        return;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if ([object respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
    }
}

static void BrowserConfigurePrivateMediaPreferences(id configuration) {
    if (configuration == nil) {
        return;
    }

    SEL preferencesSelector = NSSelectorFromString(@"preferences");
    if (![configuration respondsToSelector:preferencesSelector]) {
        return;
    }

    id preferences = ((id (*)(id, SEL))objc_msgSend)(configuration, preferencesSelector);
    if (preferences == nil) {
        return;
    }

    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setMediaSourceEnabled:", YES);
    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setManagedMediaSourceEnabled:", YES);
    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setMediaCapabilityGrantsEnabled:", YES);
    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setVideoQualityIncludesDisplayCompositingEnabled:", YES);
    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setMediaUserGestureInheritsRequiredUserGesture:", NO);
}

// WebKit normally refuses play() unless the call happens inside a user activation, while pause()
// needs no activation at all. On a tvOS remote every press *is* a user activation, but the press is
// consumed by GCEventViewController and reaches the page through stringByEvaluatingJavaScriptFromString:,
// which does not carry the activation. The result is exactly what was reported on device:
// pause works, play is rejected. Clearing the requirement makes resume work.
// WKAudiovisualMediaTypeNone == 0.
static void BrowserConfigureMediaPlaybackPolicy(id configuration) {
    if (configuration == nil) {
        return;
    }

    SEL mediaTypesSelector = NSSelectorFromString(@"setMediaTypesRequiringUserActionForPlayback:");
    if ([configuration respondsToSelector:mediaTypesSelector]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(configuration, mediaTypesSelector, (NSUInteger)0);
        NSLog(@"[MediaPolicy] mediaTypesRequiringUserActionForPlayback -> none");
    }

    // Older / private spelling on the preferences object.
    SEL preferencesSelector = NSSelectorFromString(@"preferences");
    if ([configuration respondsToSelector:preferencesSelector]) {
        id preferences = ((id (*)(id, SEL))objc_msgSend)(configuration, preferencesSelector);
        BrowserSetBooleanSelectorIfAvailable(preferences, @"_setMediaPlaybackRequiresUserGesture:", NO);
        BrowserSetBooleanSelectorIfAvailable(preferences, @"_setRequiresUserGestureForMediaPlayback:", NO);
    }
}

/// build-17: give every request a plausible top-level Referer.
///
/// Youku checks the Referer on both the document navigation and the in-page playlist/media
/// requests that follow it. A WKWebView that sends none is trivially distinguishable from a
/// desktop browser, and the player answers with "log in to continue" -- which is exactly the
/// report from a TV whose Windows Chrome, never logged in, plays the same page fine. The custom
/// user agent alone cannot fix that because it never touches Referer.
///
/// `_setReferrer:` is the same private WebKit SPI used for the other media quirks in this file.
/// It is looked up defensively: on a system that does not expose it the browser simply keeps
/// its previous behaviour, and the document-level header set by BrowserNavigationService still
/// applies to the navigation itself.
static void BrowserConfigureDefaultReferrer(id configuration) {
    if (configuration == nil) {
        return;
    }

    SEL setReferrerSelector = NSSelectorFromString(@"_setReferrer:");
    if (![configuration respondsToSelector:setReferrerSelector]) {
        NSLog(@"[Referer] _setReferrer: unavailable; document navigation keeps its header only");
        return;
    }

    // A generic, site-neutral default. Per-site origins are supplied for the document request by
    // BrowserNavigationService; this value is what pages see on sub-resource and XHR traffic, and
    // it deliberately names a real https origin instead of being empty.
    NSString *referrer = @"https://www.baidu.com/";
    ((void (*)(id, SEL, id))objc_msgSend)(configuration, setReferrerSelector, referrer);
    NSLog(@"[Referer] default referer installed");
}

static NSString *BrowserYouTubeRequestCaptureScript(void) {    return
    @"(function(){"
        "if (window.__browserYouTubeHookInstalled) { return; }"
        "window.__browserYouTubeHookInstalled = true;"
        "window.__browserYouTubeIntegrity = window.__browserYouTubeIntegrity || {};"
        "function assignIfPresent(key, value) {"
            "if (value === undefined || value === null) { return; }"
            "var stringValue = String(value || '');"
            "if (!stringValue) { return; }"
            "window.__browserYouTubeIntegrity[key] = stringValue;"
        "}"
        "function capturePayload(payload) {"
            "try {"
                "if (!payload || typeof payload !== 'object') { return; }"
                "if (payload.serviceIntegrityDimensions) {"
                    "assignIfPresent('poToken', payload.serviceIntegrityDimensions.poToken || payload.serviceIntegrityDimensions.po_token);"
                "}"
                "if (payload.context && payload.context.serviceIntegrityDimensions) {"
                    "assignIfPresent('poToken', payload.context.serviceIntegrityDimensions.poToken || payload.context.serviceIntegrityDimensions.po_token);"
                "}"
                "if (payload.context && payload.context.client) {"
                    "assignIfPresent('requestClientName', payload.context.client.clientName);"
                    "assignIfPresent('requestClientVersion', payload.context.client.clientVersion);"
                "}"
            "} catch (error) {}"
        "}"
        "function toHeaderObject(headers) {"
            "var result = {};"
            "try {"
                "if (!headers) { return result; }"
                "if (typeof Headers !== 'undefined' && headers instanceof Headers) {"
                    "headers.forEach(function(value, key) { result[String(key)] = String(value); });"
                    "return result;"
                "}"
                "if (Array.isArray(headers)) {"
                    "headers.forEach(function(entry) {"
                        "if (Array.isArray(entry) && entry.length >= 2) { result[String(entry[0])] = String(entry[1]); }"
                    "});"
                    "return result;"
                "}"
                "if (typeof headers === 'object') {"
                    "Object.keys(headers).forEach(function(key) { result[String(key)] = String(headers[key]); });"
                "}"
            "} catch (error) {}"
            "return result;"
        "}"
        "function rememberRequest(url, body, headers, transport) {"
            "try {"
                "var integrity = window.__browserYouTubeIntegrity;"
                "integrity.lastPlayerRequestURL = String(url || '');"
                "integrity.lastPlayerRequestBody = String(body || '');"
                "integrity.lastPlayerRequestHeaders = JSON.stringify(headers || {});"
                "integrity.lastPlayerRequestTransport = String(transport || '');"
                "if (!integrity.firstPlayerRequestURL) {"
                    "integrity.firstPlayerRequestURL = integrity.lastPlayerRequestURL;"
                    "integrity.firstPlayerRequestBody = integrity.lastPlayerRequestBody;"
                    "integrity.firstPlayerRequestHeaders = integrity.lastPlayerRequestHeaders;"
                    "integrity.firstPlayerRequestTransport = integrity.lastPlayerRequestTransport;"
                "}"
            "} catch (error) {}"
        "}"
        "function captureBodyStringAsync(source, bodyString, headers, transport) {"
            "try {"
                "if (bodyString && bodyString !== '[object ReadableStream]') {"
                    "rememberRequest(source.url || '', bodyString, headers || {}, transport || '');"
                    "try { capturePayload(JSON.parse(bodyString)); } catch (error) {}"
                    "return;"
                "}"
                "if (source && typeof source.clone === 'function' && typeof source.text === 'function') {"
                    "source.clone().text().then(function(text) {"
                        "rememberRequest(source.url || '', text || '', headers || {}, transport || '');"
                        "try { capturePayload(JSON.parse(text || '')); } catch (error) {}"
                    "}).catch(function(){});"
                "}"
            "} catch (error) {}"
        "}"
        "function captureRequest(input, init) {"
            "try {"
                "var url = '';"
                "if (typeof input === 'string') { url = input; }"
                "else if (input && typeof input.url === 'string') { url = input.url; }"
                "if (url.indexOf('/youtubei/v1/player') === -1) { return; }"
                "var body = (init && init.body) || (input && input.body) || null;"
                "var bodyString = '';"
                "if (typeof body === 'string') { bodyString = body; }"
                "else if (body && typeof body === 'object' && typeof body.toString === 'function') { bodyString = String(body); }"
                "var headers = toHeaderObject((init && init.headers) || (input && input.headers) || null);"
                "rememberRequest(url, bodyString, headers, 'fetch');"
                "captureBodyStringAsync((input && typeof input.clone === 'function') ? input : null, bodyString, headers, 'fetch');"
                "if (typeof bodyString !== 'string' || !bodyString || bodyString === '[object ReadableStream]') { return; }"
                "try { capturePayload(JSON.parse(bodyString)); } catch (error) {}"
            "} catch (error) {}"
        "}"
        "function captureXHRRequest(xhr, body) {"
            "try {"
                "var url = String((xhr && xhr.__browserYouTubeURL) || '');"
                "if (url.indexOf('/youtubei/v1/player') === -1) { return; }"
                "var bodyString = '';"
                "if (typeof body === 'string') { bodyString = body; }"
                "else if (body && typeof body === 'object' && typeof body.toString === 'function') { bodyString = String(body); }"
                "var headers = xhr && xhr.__browserYouTubeHeaders ? xhr.__browserYouTubeHeaders : {};"
                "rememberRequest(url, bodyString, headers, 'xhr');"
                "if (typeof bodyString !== 'string' || !bodyString) { return; }"
                "try { capturePayload(JSON.parse(bodyString)); } catch (error) {}"
            "try { capturePayload(JSON.parse(body)); } catch (error) {}"
            "} catch (error) {}"
        "}"
        "var cfg = (window.ytcfg && window.ytcfg.data_) || {};"
        "assignIfPresent('poToken', cfg.PO_TOKEN || cfg.po_token || cfg.POTOKEN);"
        "if (cfg.SERVICE_INTEGRITY_DIMENSIONS) {"
            "assignIfPresent('poToken', cfg.SERVICE_INTEGRITY_DIMENSIONS.poToken || cfg.SERVICE_INTEGRITY_DIMENSIONS.po_token);"
        "}"
        "if (cfg.WEB_PLAYER_CONTEXT_CONFIGS) {"
            "var watchConfig = cfg.WEB_PLAYER_CONTEXT_CONFIGS.WEB_PLAYER_CONTEXT_CONFIG_ID_KEVLAR_WATCH || {};"
            "if (watchConfig.serviceIntegrityDimensions) {"
                "assignIfPresent('poToken', watchConfig.serviceIntegrityDimensions.poToken || watchConfig.serviceIntegrityDimensions.po_token);"
            "}"
        "}"
        "if (window.fetch) {"
            "var originalFetch = window.fetch;"
            "window.fetch = function(input, init) {"
                "captureRequest(input, init);"
                "return originalFetch.apply(this, arguments);"
            "};"
        "}"
        "if (window.XMLHttpRequest && window.XMLHttpRequest.prototype) {"
            "var originalOpen = window.XMLHttpRequest.prototype.open;"
            "var originalSend = window.XMLHttpRequest.prototype.send;"
            "var originalSetRequestHeader = window.XMLHttpRequest.prototype.setRequestHeader;"
            "window.XMLHttpRequest.prototype.open = function(method, url) {"
                "this.__browserYouTubeURL = String(url || '');"
                "this.__browserYouTubeHeaders = {};"
                "return originalOpen.apply(this, arguments);"
            "};"
            "window.XMLHttpRequest.prototype.setRequestHeader = function(key, value) {"
                "try {"
                    "if (!this.__browserYouTubeHeaders) { this.__browserYouTubeHeaders = {}; }"
                    "this.__browserYouTubeHeaders[String(key)] = String(value);"
                "} catch (error) {}"
                "return originalSetRequestHeader.apply(this, arguments);"
            "};"
            "window.XMLHttpRequest.prototype.send = function(body) {"
                "captureXHRRequest(this, body);"
                "return originalSend.apply(this, arguments);"
            "};"
        "}"
    "})();";
}

NSString * const BrowserPseudoFullscreenRequestNotification = @"BrowserPseudoFullscreenRequestNotification";
NSString * const BrowserPseudoFullscreenRequestEnterKey = @"enter";

static NSMutableArray *BrowserScriptMessageHandlerRetainer(void) {
    static NSMutableArray *handlers = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handlers = [NSMutableArray array];
    });
    return handlers;
}

// WKScriptMessageHandler implemented at runtime: we cannot import WebKit headers here, so the
// class is built with the ObjC runtime and forwards the page's fullscreen request as a notification.
static void BrowserPseudoFullscreenMessageReceived(id self, SEL _cmd, id userContentController, id message) {
    (void)self;
    (void)_cmd;
    (void)userContentController;
    if (message == nil) {
        return;
    }

    id body = nil;
    SEL bodySelector = NSSelectorFromString(@"body");
    if ([message respondsToSelector:bodySelector]) {
        body = ((id (*)(id, SEL))objc_msgSend)(message, bodySelector);
    }
    NSString *action = [body isKindOfClass:[NSString class]] ? (NSString *)body : @"";
    BOOL enter = ![action isEqualToString:@"exit"];
    NSLog(@"[PseudoFullscreen] page request action=%@ enter=%@", action, enter ? @"YES" : @"NO");

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:BrowserPseudoFullscreenRequestNotification
                                                            object:nil
                                                          userInfo:@{BrowserPseudoFullscreenRequestEnterKey: @(enter)}];
    });
}

static Class BrowserScriptMessageHandlerClass(void) {
    static Class handlerClass = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handlerClass = objc_allocateClassPair([NSObject class], "BrowserPseudoFullscreenMessageHandler", 0);
        if (handlerClass == Nil) {
            return;
        }
        SEL selector = NSSelectorFromString(@"userContentController:didReceiveScriptMessage:");
        class_addMethod(handlerClass,
                        selector,
                        (IMP)BrowserPseudoFullscreenMessageReceived,
                        "v@:@@");
        objc_registerClassPair(handlerClass);
    });
    return handlerClass;
}

static NSString * const kBrowserPseudoFullscreenMessageName = @"browserPseudoFullscreen";

// Hijack the page's own fullscreen API so tapping the site's fullscreen button routes to the
// app's pseudo-fullscreen styling instead of WebKit's native fullscreen container.
// The native container lives in a separate window above the app, which buries the cursor view
// and always keeps the browser chrome visible.
static NSString *BrowserFullscreenInterceptScript(void) {
    NSString *source =
    @"(function(){"
        // ---- desktop environment normalisation ---------------------------------------------
        // customUserAgent is already a desktop Safari/Chrome string, but tvOS WebKit still exposes
        // device fingerprints (navigator.platform = AppleTV, etc.). Sites that gate playback behind
        // "install our app" read those extra fields, so align them with the user agent. The UA
        // itself is NOT overridden here: the Advanced Menu UA switch must still work.
        // build-16: normalise EVERY frame, not just the top frame. Sites such as Youku run their
        // playback / environment checks inside iframes; leaving child frames as AppleTV broke
        // navigation there. The per-frame cost is a handful of property definitions.
        "try{"
            "var nav=window.navigator;"
            "if(nav){"
                "var ua=String(nav.userAgent||'');"
                "var mobile=/iPhone|iPad|iPod|Mobile/.test(ua);"
                "var plat=mobile?'iPhone':'MacIntel';"
                "var mt=mobile?5:0;"
                "try{Object.defineProperty(nav,'platform',{get:function(){return plat;},configurable:true});}catch(e){}"
                "try{Object.defineProperty(nav,'maxTouchPoints',{get:function(){return mt;},configurable:true});}catch(e){}"
                "try{Object.defineProperty(nav,'vendor',{get:function(){return 'Apple Computer, Inc.';},configurable:true});}catch(e){}"
                "try{Object.defineProperty(nav,'standalone',{get:function(){return false;},configurable:true});}catch(e){}"
                "try{Object.defineProperty(nav,'hardwareConcurrency',{get:function(){return 8;},configurable:true});}catch(e){}"
                "try{Object.defineProperty(nav,'deviceMemory',{get:function(){return 8;},configurable:true});}catch(e){}"
                "try{Object.defineProperty(nav,'languages',{get:function(){return ['zh-CN','zh','en'];},configurable:true});}catch(e){}"
                // build-17: when the user picks the desktop-Chrome identity, the HTTP User-Agent
                // header alone is not enough. Sites such as iQiyi read navigator.userAgent /
                // appVersion / userAgentData from JavaScript and compare them with the header; a
                // WebKit JS string next to a Chrome header is an instant "page load error".
                // Only the Chrome mode rewrites these, so a WebKit engine still looks like WebKit.
                "var isChrome=/Chrome\\//.test(ua);"
                "if(isChrome){"
                    "try{Object.defineProperty(nav,'userAgent',{get:function(){return ua;},configurable:true});}catch(e){}"
                    "try{Object.defineProperty(nav,'appVersion',{get:function(){return ua.replace(/^Mozilla\\//,'');},configurable:true});}catch(e){}"
                    "try{Object.defineProperty(nav,'appName',{get:function(){return 'Netscape';},configurable:true});}catch(e){}"
                    "try{Object.defineProperty(nav,'vendor',{get:function(){return 'Google Inc.';},configurable:true});}catch(e){}"
                    // Chrome's UA-CH surface. Without it a site that asks for high-entropy hints
                    // sees "no userAgentData" on a UA claiming to be Chrome, which is itself a bot
                    // signal; with it the two answers agree.
                    "try{"
                        "var uad={brands:[{brand:'Chromium',version:'126'},{brand:'Google Chrome',version:'126'},{brand:'Not.A/Brand',version:'24'}],"
                            "mobile:false,platform:'macOS',"
                            "getHighEntropyValues:function(){"
                                "return Promise.resolve({architecture:'x86',bitness:'64',model:'',platform:'macOS',"
                                    "platformVersion:'14.0.0',uaFullVersion:'126.0.0.0',fullVersionList:this.brands,wow64:false});"
                            "}};"
                        "Object.defineProperty(nav,'userAgentData',{get:function(){return uad;},configurable:true});"
                    "}catch(e){}"
                    // The presence of window.chrome is a very common Chrome test.
                    "try{if(!window.chrome){window.chrome={runtime:{},app:{isInstalled:false},csi:function(){return {};},loadTimes:function(){return {};}};}}catch(e){}"
                "}"
            "}"
        "}catch(e){}"
        // Click-assist for tiny controls (a close "x" is often a 12-16 px glyph inside a div).
        // Sample a ring around the cursor and snap to the closest interactive element within the
        // radius. Exposed for BrowserDOMInteractionService's hit-test wrapper in the main frame.
        "function pfNearestInteractive(px,py,radius,selector){"
            "var best=null,bestD=radius+1;"
            "var offs=[[0,0],[1,0],[-1,0],[0,1],[0,-1],[1,1],[-1,1],[1,-1],[-1,-1],[2,0],[-2,0],[0,2],[0,-2]];"
            "for(var i=0;i<offs.length;i++){"
                "var sx=px+offs[i][0]*radius*0.5,sy=py+offs[i][1]*radius*0.5;"
                "var hit=document.elementFromPoint(sx,sy);"
                "if(!hit){continue;}"
                "var cand=hit,found=null;"
                "while(cand){if(cand.matches&&cand.matches(selector)){found=cand;break;}cand=cand.parentElement;}"
                "if(!found){continue;}"
                "var r=found.getBoundingClientRect();"
                // build-16: only snap to genuinely SMALL controls. Snapping onto a large poster
                // card or a big link hijacks clicks on video/catalogue pages (Youku regression).
                "if(!r||r.width<=0||r.height<=0||r.width>44||r.height>44){continue;}"
                "var cx=r.left+r.width/2,cy=r.top+r.height/2;"
                "var d=Math.sqrt((cx-px)*(cx-px)+(cy-py)*(cy-py));"
                "if(d<=radius&&d<bestD){best=found;bestD=d;}"
            "}"
            "return best;"
        "}"
        "window.__browserNearestInteractive=pfNearestInteractive;"
        "var MSG='__BROWSER_PF_MSG__';"
        "function post(enter){"
            "try{"
                "if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers[MSG]){"
                    "window.webkit.messageHandlers[MSG].postMessage(enter?'enter':'exit');"
                    "return true;"
                "}"
            "}catch(e){}"
            "return false;"
        "}"
        "function block(fn){"
            "return function(){"
                "post(fn);"
                "return Promise.resolve();"
            "};"
        "}"
        "try{"
            "if(window.Element&&Element.prototype){"
                "Element.prototype.requestFullscreen=block('enter');"
                "Element.prototype.webkitRequestFullscreen=block('enter');"
                "Element.prototype.webkitRequestFullScreen=block('enter');"
                "Element.prototype.mozRequestFullScreen=block('enter');"
                "Element.prototype.msRequestFullscreen=block('enter');"
            "}"
        "}catch(e){}"
        "try{"
            "if(window.HTMLVideoElement&&HTMLVideoElement.prototype){"
                "HTMLVideoElement.prototype.webkitEnterFullscreen=function(){"
                    "post('enter');"
                "};"
                "HTMLVideoElement.prototype.webkitEnterFullScreen=function(){"
                    "post('enter');"
                "};"
                "HTMLVideoElement.prototype.webkitExitFullscreen=function(){"
                    "post('exit');"
                "};"
            "}"
        "}catch(e){}"
        "try{"
            "if(window.Document&&Document.prototype){"
                "Object.defineProperty(Document.prototype,'fullscreenEnabled',{configurable:true,get:function(){return true;}});"
                "Object.defineProperty(Document.prototype,'webkitFullscreenEnabled',{configurable:true,get:function(){return true;}});"
                "Object.defineProperty(Document.prototype,'fullscreenElement',{configurable:true,get:function(){return null;}});"
                "Object.defineProperty(Document.prototype,'webkitFullscreenElement',{configurable:true,get:function(){return null;}});"
                "Document.prototype.exitFullscreen=block('exit');"
                "Document.prototype.webkitExitFullscreen=block('exit');"
            "}"
        "}catch(e){}"
        "document.addEventListener('webkitfullscreenchange',function(ev){ev.stopImmediatePropagation();},true);"
        "document.addEventListener('fullscreenchange',function(ev){ev.stopImmediatePropagation();},true);"
        "window.__browserFullscreenHijacked=true;"

        // ---- in-frame pseudo fullscreen engine -------------------------------------------
        // Every frame runs this script, so a same- or cross-origin player iframe can style its
        // own <video>. The top document asks each frame to apply the styling itself; that is the
        // only way to reach a video inside a cross-origin iframe.
        "var PF_STYLE='__browser_pf_style';"
        "var PF_VIDEO='data-browser-pf-video';"
        "var PF_ANCESTOR='data-browser-pf-ancestor';"
        "var PF_ROOT='data-browser-pf';"
        "var PF_CSS='['+PF_VIDEO+']{position:fixed!important;left:0!important;top:0!important;right:0!important;bottom:0!important;width:100vw!important;height:100vh!important;max-width:none!important;max-height:none!important;min-width:0!important;min-height:0!important;margin:0!important;padding:0!important;border:0!important;z-index:2147483647!important;object-fit:contain!important;background:#000!important;transform:none!important;}['+PF_ANCESTOR+']{transform:none!important;filter:none!important;perspective:none!important;will-change:auto!important;contain:none!important;overflow:visible!important;}html['+PF_ROOT+'],html['+PF_ROOT+'] body{overflow:hidden!important;}';"
        "function pfEnsureStyle(){"
            "try{"
                "if(document.getElementById(PF_STYLE)){return;}"
                "var st=document.createElement('style');"
                "st.id=PF_STYLE;"
                "st.textContent=PF_CSS;"
                "(document.head||document.documentElement).appendChild(st);"
            "}catch(e){}"
        "}"
        "function pfArea(el){try{var r=el.getBoundingClientRect();return Math.max(0,r.width)*Math.max(0,r.height);}catch(e){return 0;}}"
        "function pfPick(){"
            "var list=[];"
            "try{var vs=document.querySelectorAll('video');for(var i=0;i<vs.length;i++){list.push(vs[i]);}}catch(e){}"
            "if(!list.length){return null;}"
            "var playing=[];"
            "for(var p=0;p<list.length;p++){var v=list[p];if(v.readyState>0&&!v.paused&&!v.ended){playing.push(v);}}"
            "var pool=playing.length?playing:list;"
            "var best=pool[0];var bestArea=pfArea(pool[0]);"
            "for(var k=1;k<pool.length;k++){var a=pfArea(pool[k]);if(a>bestArea){bestArea=a;best=pool[k];}}"
            "return best;"
        "}"
        "function pfBiggestFrame(){"
            "var best=null;var bestA=0;"
            "try{"
                "var fs=document.querySelectorAll('iframe');"
                "for(var i=0;i<fs.length;i++){var a=pfArea(fs[i]);if(a>bestA){bestA=a;best=fs[i];}}"
            "}catch(e){}"
            "return bestA>0?best:null;"
        "}"
        "function pfApply(){"
            "var video=pfPick();"
            "if(video){"
                "pfEnsureStyle();"
                "var node=video.parentElement;"
                "while(node){try{node.setAttribute(PF_ANCESTOR,'1');}catch(e){} node=node.parentElement;}"
                "try{video.setAttribute(PF_VIDEO,'1');}catch(e){}"
                "try{document.documentElement.setAttribute(PF_ROOT,'1');}catch(e){}"
                "window.__browserPfVideo=video;"
                "return 'ok';"
            "}"
            // No video in this document: promote the largest iframe so a player living in a
            // (possibly cross-origin) child frame can still fill the screen.
            "var fr=pfBiggestFrame();"
            "if(fr){"
                "pfEnsureStyle();"
                "try{fr.setAttribute(PF_VIDEO,'1');}catch(e){}"
                "try{document.documentElement.setAttribute(PF_ROOT,'1');}catch(e){}"
                "window.__browserPfFrame=fr;"
                "return 'iframe';"
            "}"
            "return 'no-video';"
        "}"
        "function pfClear(){"
            "try{window.__browserPfVideo=null;}catch(e){}"
            "try{"
                "var ns=document.querySelectorAll('['+PF_VIDEO+'],['+PF_ANCESTOR+']');"
                "for(var i=0;i<ns.length;i++){ns[i].removeAttribute(PF_VIDEO);ns[i].removeAttribute(PF_ANCESTOR);}"
            "}catch(e){}"
            "try{document.documentElement.removeAttribute(PF_ROOT);}catch(e){}"
            "try{var st=document.getElementById(PF_STYLE);if(st&&st.parentNode){st.parentNode.removeChild(st);}}catch(e){}"
            "return 'ok';"
        "}"
        "window.__browserPfApply=pfApply;"
        "window.__browserPfClear=pfClear;"

        // ---- playback control API (used by the remote in fullscreen) ----------------------
        // Returns a compact state string: "<current>|<duration>|<paused 0/1>|<title>"
        "function pfActiveVideo(){"
            "var v=window.__browserPfVideo;"
            "if(v&&v.ownerDocument&&v.ownerDocument.contains(v)){return v;}"
            "return pfPick();"
        "}"
        "function pfState(){"
            "var v=pfActiveVideo();"
            "if(!v){return 'none';}"
            "var cur=0;var dur=0;"
            "try{cur=Number(v.currentTime)||0;}catch(e){}"
            "try{dur=Number(v.duration);}catch(e){}"
            "if(!isFinite(dur)||dur<0){dur=0;}"
            "var paused=v.paused?1:0;"
            "return cur.toFixed(2)+'|'+dur.toFixed(2)+'|'+paused;"
        "}"
        "function pfSeek(delta){"
            "var v=pfActiveVideo();"
            "if(!v){return 'none';}"
            "try{"
                "var dur=Number(v.duration);"
                "var target=(Number(v.currentTime)||0)+Number(delta);"
                "if(target<0){target=0;}"
                "if(isFinite(dur)&&dur>0&&target>dur-0.25){target=Math.max(0,dur-0.25);}"
                "v.currentTime=target;"
                "return target.toFixed(2);"
            "}catch(e){return 'error';}"
        "}"
        "function pfSeekTo(ratio){"
            "var v=pfActiveVideo();"
            "if(!v){return 'none';}"
            "try{"
                "var dur=Number(v.duration);"
                "if(!isFinite(dur)||dur<=0){return 'error';}"
                "var r=Number(ratio);if(!isFinite(r)){return 'error';}"
                "if(r<0){r=0;}if(r>1){r=1;}"
                "v.currentTime=dur*r;"
                "return v.currentTime.toFixed(2);"
            "}catch(e){return 'error';}"
        "}"
        "function pfSyntheticClick(el){"
            "try{"
                "if(!el){return;}"
                "var opts={bubbles:true,cancelable:true,composed:true};"
                "try{el.dispatchEvent(new PointerEvent('pointerdown',opts));}catch(e){}"
                "try{el.dispatchEvent(new MouseEvent('mousedown',opts));}catch(e){}"
                "try{el.dispatchEvent(new PointerEvent('pointerup',opts));}catch(e){}"
                "try{el.dispatchEvent(new MouseEvent('mouseup',opts));}catch(e){}"
                "try{el.dispatchEvent(new MouseEvent('click',opts));}catch(e){}"
            "}catch(e){}"
        "}"
        // Resume is the fragile half: pause() needs no user activation, play() does. The app clears
        // WebKit's activation requirement, but a player library can still veto a direct play() and
        // re-pause the element, so fall back to clicking the element the way a viewer would.
        "function pfTogglePlay(){"
            "var v=pfActiveVideo();"
            "if(!v){return 'none';}"
            "try{"
                "if(v.paused){"
                    "var p=null;"
                    "try{p=v.play();}catch(e){p=null;}"
                    "if(p&&typeof p.catch==='function'){"
                        "p.catch(function(){pfSyntheticClick(v.parentElement||v);});"
                    "}else if(!p){"
                        "pfSyntheticClick(v.parentElement||v);"
                    "}"
                    // Verify a moment later: if the element is still paused, click it as well.
                    "setTimeout(function(){"
                        "try{"
                            "if(v.paused){"
                                "var q=null;try{q=v.play();}catch(e){q=null;}"
                                "if(q&&typeof q.catch==='function'){q.catch(function(){pfSyntheticClick(v.parentElement||v);});}"
                            "}"
                        "}catch(e){}"
                    "},260);"
                    "return 'playing';"
                "}"
                "v.pause();return 'paused';"
            "}catch(e){"
                "pfSyntheticClick(v.parentElement||v);"
                "return 'clicked';"
            "}"
        "}"
        "function pfResumePlay(){"
            "var v=pfActiveVideo();"
            "if(!v){return 'none';}"
            "if(!v.paused){return 'already';}"
            "var target=v.parentElement||v;"
            "var p=null;"
            "try{p=v.play();}catch(e){p=null;}"
            "if(p&&typeof p.catch==='function'){"
                "p.catch(function(){pfSyntheticClick(target);});"
            "}else if(!p){"
                "pfSyntheticClick(target);"
            "}"
            "setTimeout(function(){"
                "try{"
                    "if(v.paused){"
                        "var q=null;try{q=v.play();}catch(e){q=null;}"
                        "if(q&&typeof q.catch==='function'){q.catch(function(){pfSyntheticClick(target);});}"
                        "else if(!q){pfSyntheticClick(target);}"
                    "}"
                "}catch(e){}"
            "},260);"
            "return 'playing';"
        "}"
        // Select outside fullscreen: only toggle when the cursor actually sits on a video, so
        // Select still clicks links everywhere else. elementFromPoint can land on a control overlay,
        // so walk up a few ancestors before falling back to a bounding-rect hit test. A hit on an
        // iframe is reported separately: the player may live in a cross-origin child frame.
        "function pfCursorTogglePlay(x,y){"
            "var v=null;"
            "try{"
                "var el=document.elementFromPoint(x,y);"
                "var node=el;"
                "for(var i=0;node&&i<6;i++,node=node.parentElement){"
                    "if(node.tagName==='VIDEO'){v=node;break;}"
                "}"
            "}catch(e){}"
            "if(!v){"
                "try{"
                    "var vs=document.querySelectorAll('video');"
                    "for(var j=0;j<vs.length;j++){"
                        "var r=vs[j].getBoundingClientRect();"
                        "if(r.width>0&&r.height>0&&x>=r.left&&x<=r.right&&y>=r.top&&y<=r.bottom){v=vs[j];break;}"
                    "}"
                "}catch(e){}"
            "}"
            "if(!v){"
                "try{"
                    "var fs=document.querySelectorAll('iframe');"
                    "for(var k=0;k<fs.length;k++){"
                        "var fr=fs[k].getBoundingClientRect();"
                        "if(fr.width>0&&fr.height>0&&x>=fr.left&&x<=fr.right&&y>=fr.top&&y<=fr.bottom){return 'iframe';}"
                    "}"
                "}catch(e){}"
                "return 'none';"
            "}"
            "window.__browserPfVideo=v;"
            "return pfTogglePlay();"
        "}"
        "function pfDuration(){"
            "var v=pfActiveVideo();"
            "if(!v){return 0;}"
            "try{var d=Number(v.duration);return (isFinite(d)&&d>0)?d:0;}catch(e){return 0;}"
        "}"
        "window.__browserPfState=pfState;"
        "window.__browserPfSeek=pfSeek;"
        "window.__browserPfSeekTo=pfSeekTo;"
        "window.__browserPfTogglePlay=pfTogglePlay;"
        "window.__browserPfResumePlay=pfResumePlay;"
        "window.__browserPfCursorTogglePlay=pfCursorTogglePlay;"
        "window.__browserPfDuration=pfDuration;"
        "window.__browserPfActiveVideo=pfActiveVideo;"

        // Ask every child frame for its playback state and merge the best answer, so the
        // remote can control a player that lives inside an iframe.
        // A cross-origin child cannot be read, so each frame also answers its parent over
        // postMessage; the answer is cached in __browserPfRemoteState for the next poll.
        "function pfCollectState(){"
            "var best=null;"
            "function consider(s){"
                "if(!s||typeof s!=='string'){return;}"
                "var p=s.split('|');"
                "if(p.length<3){return;}"
                "var dur=parseFloat(p[1])||0;"
                "if(dur<=0){return;}"
                "if(!best||dur>(parseFloat(best.split('|')[1])||0)){best=s;}"
            "}"
            "var mine=pfState();"
            "if(mine!=='none'){consider(mine);}"
            "try{consider(window.__browserPfRemoteState);}catch(e){}"
            "try{"
                "var fs=document.querySelectorAll('iframe');"
                "for(var i=0;i<fs.length;i++){"
                    "var cd=null;"
                    "try{cd=fs[i].contentDocument||null;}catch(e){cd=null;}"
                    "if(cd&&cd.defaultView&&typeof cd.defaultView.__browserPfCollectState==='function'){"
                        "try{consider(cd.defaultView.__browserPfCollectState());}catch(e){}"
                    "}"
                "}"
            "}catch(e){}"
            // Refresh the cached cross-origin answers for the next poll.
            "try{pfFanOutMessage({__browserPf:'state'});}catch(e){}"
            "return best||mine;"
        "}"
        "window.__browserPfCollectState=pfCollectState;"

        // Cross-frame fan-out: same-origin children are driven directly, cross-origin children
        // get the message so they can style themselves.
        "function pfFanOut(cmd){"
            "var frames=[];"
            "try{var fs=document.querySelectorAll('iframe');for(var i=0;i<fs.length;i++){frames.push(fs[i]);}}catch(e){}"
            "var acted=false;"
            "for(var j=0;j<frames.length;j++){"
                "var fr=frames[j];"
                "var cd=null;"
                "try{cd=fr.contentDocument||null;}catch(e){cd=null;}"
                "if(cd&&cd.defaultView&&typeof cd.defaultView.__browserPfApply==='function'){"
                    // Only a child that actually found a target counts, otherwise a page with an
                    // unrelated (video-less) iframe would look like it has something to promote.
                    "try{var said=cd.defaultView.__browserPfApply();"
                        "if(said==='ok'||said==='iframe'){acted=true;}"
                    "}catch(e){}"
                    "try{if(cmd==='clear'&&typeof cd.defaultView.__browserPfClear==='function'){cd.defaultView.__browserPfClear();}}catch(e){}"
                "}else{"
                    "try{fr.contentWindow.postMessage({__browserPf:cmd},'*');}catch(e){}"
                "}"
            "}"
            "return acted;"
        "}"
        "window.__browserPfFanOut=pfFanOut;"

        // Deliver a control message to every child frame (downward only, so no echo loops).
        "function pfFanOutMessage(payload){"
            "try{"
                "var fs=document.querySelectorAll('iframe');"
                "for(var i=0;i<fs.length;i++){"
                    "try{fs[i].contentWindow.postMessage(payload,'*');}catch(e){}"
                "}"
            "}catch(e){}"
        "}"
        "window.__browserPfFanOutMessage=pfFanOutMessage;"

        // build-16: episode/playlist lists are inner overflow containers, not the document.
        // Walk up from the element under the cursor and scroll the first scrollable ancestor.
        // 'inner' = an inner container moved (native UIScrollView must NOT also scroll);
        // 'iframe' = the hit element is an iframe, delegated to that child frame;
        // 'none' = nothing inner moved, native document scroll is the fallback.
        // overflow:hidden is accepted on purpose: many sites build custom scrollers that still
        // respond to a programmatic scrollTop assignment.
        "function pfScrollAtPoint(px,py,dx,dy){"
            "var el=null;"
            "try{el=document.elementFromPoint(px,py);}catch(e){return 'none';}"
            "if(!el){return 'none';}"
            "if(el.tagName==='IFRAME'||el.tagName==='FRAME'){"
                "var r=null;try{r=el.getBoundingClientRect();}catch(e){}"
                "var ix=px,iy=py;"
                "if(r){ix=px-r.left;iy=py-r.top;}"
                "try{el.contentWindow.postMessage({__browserPf:'scrollAt',x:ix,y:iy,dx:dx,dy:dy},'*');}catch(e){}"
                "return 'iframe';"
            "}"
            "var node=el;"
            "for(var depth=0;node&&node.nodeType===1&&depth<40;depth++){"
                "if(node===document.body||node===document.documentElement){break;}"
                "var canY=node.scrollHeight>node.clientHeight+1;"
                "var canX=node.scrollWidth>node.clientWidth+1;"
                "if(canY||canX){"
                    "var st=null;try{st=window.getComputedStyle(node);}catch(e){}"
                    "var oy=st?(st.overflowY||''):'visible';"
                    "var ox=st?(st.overflowX||''):'visible';"
                    "var bt=node.scrollTop,bl=node.scrollLeft;"
                    "if(canY&&oy!=='visible'){node.scrollTop=bt+dy;}"
                    "if(canX&&ox!=='visible'){node.scrollLeft=bl+dx;}"
                    "if(node.scrollTop!==bt||node.scrollLeft!==bl){return 'inner';}"
                "}"
                "node=node.parentNode;"
            "}"
            "return 'none';"
        "}"
        "window.__browserPfScrollAtPoint=pfScrollAtPoint;"

        "if(!window.__browserPfListenerInstalled){"
            "window.__browserPfListenerInstalled=true;"
            "window.addEventListener('message',function(ev){"
                "var d=ev&&ev.data;"
                "if(!d||typeof d!=='object'||!d.__browserPf){return;}"
                "try{"
                    "if(d.__browserPf==='apply'){pfApply();pfFanOut('apply');}"
                    "else if(d.__browserPf==='clear'){pfClear();pfFanOut('clear');}"
                    "else if(d.__browserPf==='seek'&&typeof d.delta!=='undefined'){"
                        "pfSeek(d.delta);"
                        "pfFanOutMessage({__browserPf:'seek',delta:d.delta});"
                    "}"
                    "else if(d.__browserPf==='seekTo'&&typeof d.ratio!=='undefined'){"
                        "pfSeekTo(d.ratio);"
                        "pfFanOutMessage({__browserPf:'seekTo',ratio:d.ratio});"
                    "}"
                    "else if(d.__browserPf==='toggle'){"
                        "pfTogglePlay();"
                        "pfFanOutMessage({__browserPf:'toggle'});"
                    "}"
                    "else if(d.__browserPf==='resume'){"
                        "pfResumePlay();"
                        "pfFanOutMessage({__browserPf:'resume'});"
                    "}"
                    "else if(d.__browserPf==='cursorToggle'&&typeof d.x!=='undefined'&&typeof d.y!=='undefined'){"
                        "pfCursorTogglePlay(d.x,d.y);"
                        "pfFanOutMessage({__browserPf:'cursorToggle',x:d.x,y:d.y});"
                    "}"
                    "else if(d.__browserPf==='state'){"
                        // Report upward so a cross-origin parent can still read this frame.
                        "var s=pfState();"
                        "try{if(window.parent&&window.parent!==window){window.parent.postMessage({__browserPf:'stateReply',state:s},'*');}}catch(e){}"
                        "pfFanOutMessage({__browserPf:'state'});"
                    "}"
                    "else if(d.__browserPf==='stateReply'&&typeof d.state==='string'){"
                        "try{window.__browserPfRemoteState=d.state;}catch(e){}"
                        // Keep bubbling up: a player nested two frames deep must still reach the top.
                        "try{if(window.parent&&window.parent!==window){window.parent.postMessage({__browserPf:'stateReply',state:d.state},'*');}}catch(e){}"
                    "}"
                    // build-16: a delegated scroll from the parent. No inner container means this
                    // frame's own document should scroll (the page-level UIScrollView cannot).
                    "else if(d.__browserPf==='scrollAt'&&typeof d.dx!=='undefined'&&typeof d.dy!=='undefined'){"
                        "var said=pfScrollAtPoint(Number(d.x)||0,Number(d.y)||0,Number(d.dx)||0,Number(d.dy)||0);"
                        "if(said==='none'){try{window.scrollBy(Number(d.dx)||0,Number(d.dy)||0);}catch(e){}}"
                    "}"
                "}catch(e){}"
            "},false);"
        "}"
    "})();";

    return [source stringByReplacingOccurrencesOfString:@"__BROWSER_PF_MSG__"
                                             withString:kBrowserPseudoFullscreenMessageName];
}

static void BrowserInstallFullscreenInterceptUserScript(id configuration) {
    if (configuration == nil) {
        return;
    }

    Class userScriptClass = NSClassFromString(kBrowserUserScriptClassName);
    if (userScriptClass == Nil) {
        return;
    }

    SEL userContentControllerGetter = NSSelectorFromString(@"userContentController");
    SEL setUserContentControllerSelector = NSSelectorFromString(@"setUserContentController:");
    SEL addUserScriptSelector = NSSelectorFromString(@"addUserScript:");
    SEL userScriptInitializer = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    if (![configuration respondsToSelector:userContentControllerGetter] ||
        ![configuration respondsToSelector:setUserContentControllerSelector] ||
        ![userScriptClass instancesRespondToSelector:userScriptInitializer]) {
        return;
    }

    Class userContentControllerClass = NSClassFromString(kBrowserUserContentControllerClassName);
    id userContentController = ((id (*)(id, SEL))objc_msgSend)(configuration, userContentControllerGetter);
    if (userContentController == nil && userContentControllerClass != Nil) {
        userContentController = ((id (*)(id, SEL))objc_msgSend)((id)userContentControllerClass, @selector(new));
        ((void (*)(id, SEL, id))objc_msgSend)(configuration, setUserContentControllerSelector, userContentController);
    }
    if (userContentController == nil || ![userContentController respondsToSelector:addUserScriptSelector]) {
        return;
    }

    id userScript = ((id (*)(id, SEL))objc_msgSend)((id)userScriptClass, @selector(alloc));
    // WKUserScriptInjectionTimeAtDocumentStart == 0, forMainFrameOnly:NO so iframes get it too.
    userScript = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(userScript,
                                                                     userScriptInitializer,
                                                                     BrowserFullscreenInterceptScript(),
                                                                     0,
                                                                     NO);
    if (userScript != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(userContentController, addUserScriptSelector, userScript);
    }

    // Register the message handler so the injected script can talk back to native.
    SEL addHandlerSelector = NSSelectorFromString(@"addScriptMessageHandler:name:");
    Class handlerClass = BrowserScriptMessageHandlerClass();
    if (handlerClass != Nil && [userContentController respondsToSelector:addHandlerSelector]) {
        id handler = ((id (*)(id, SEL))objc_msgSend)((id)handlerClass, @selector(new));
        if (handler != nil) {
            [BrowserScriptMessageHandlerRetainer() addObject:handler];
            ((void (*)(id, SEL, id, id))objc_msgSend)(userContentController,
                                                      addHandlerSelector,
                                                      handler,
                                                      kBrowserPseudoFullscreenMessageName);
        }
    }
}

static void BrowserInstallYouTubeCaptureUserScript(id configuration) {
    if (configuration == nil) {
        return;
    }

    Class userContentControllerClass = NSClassFromString(kBrowserUserContentControllerClassName);
    Class userScriptClass = NSClassFromString(kBrowserUserScriptClassName);
    if (userContentControllerClass == Nil || userScriptClass == Nil) {
        return;
    }

    SEL userContentControllerGetter = NSSelectorFromString(@"userContentController");
    SEL setUserContentControllerSelector = NSSelectorFromString(@"setUserContentController:");
    id userContentController = nil;
    if ([configuration respondsToSelector:userContentControllerGetter]) {
        userContentController = ((id (*)(id, SEL))objc_msgSend)(configuration, userContentControllerGetter);
    }

    if (userContentController == nil && [configuration respondsToSelector:setUserContentControllerSelector]) {
        userContentController = ((id (*)(id, SEL))objc_msgSend)((id)userContentControllerClass, @selector(new));
        ((void (*)(id, SEL, id))objc_msgSend)(configuration, setUserContentControllerSelector, userContentController);
    }

    SEL addUserScriptSelector = NSSelectorFromString(@"addUserScript:");
    SEL userScriptInitializer = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    if (userContentController == nil ||
        ![userContentController respondsToSelector:addUserScriptSelector] ||
        ![userScriptClass instancesRespondToSelector:userScriptInitializer]) {
        return;
    }

    id userScript = ((id (*)(id, SEL))objc_msgSend)((id)userScriptClass, @selector(alloc));
    userScript = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(userScript, userScriptInitializer, BrowserYouTubeRequestCaptureScript(), 0, NO);
    if (userScript != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(userContentController, addUserScriptSelector, userScript);
    }
}

@interface BrowserWebView ()

@property (nullable, nonatomic, strong) id runtimeWebView;
@property (nullable, nonatomic, strong) NSURLRequest *lastRequest;
@property (nullable, nonatomic, copy) NSString *lastTitle;
@property (nonatomic, copy) NSString *userAgent;
@property (nonatomic) BOOL loading;

@end

@implementation BrowserWebView

- (instancetype)initWithFrame:(CGRect)frame {
    return [self initWithUserAgent:nil allowsInlineMediaPlayback:YES];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInitWithUserAgent:nil allowsInlineMediaPlayback:YES];
    }
    return self;
}

- (instancetype)initWithUserAgent:(NSString *)userAgent allowsInlineMediaPlayback:(BOOL)allowsInlineMediaPlayback {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        [self commonInitWithUserAgent:userAgent allowsInlineMediaPlayback:allowsInlineMediaPlayback];
    }
    return self;
}

- (void)commonInitWithUserAgent:(NSString *)userAgent allowsInlineMediaPlayback:(BOOL)allowsInlineMediaPlayback {
    BrowserEnsureWebKitRuntimeLoaded();

    self.backgroundColor = UIColor.blackColor;
    self.userAgent = userAgent;
    self.scalesPageToFit = NO;

    Class configurationClass = NSClassFromString(kBrowserWebViewConfigurationClassName);
    Class webViewClass = NSClassFromString(kBrowserWebViewClassName);
    if (configurationClass == Nil || webViewClass == Nil) {
        return;
    }

    id configuration = ((id (*)(id, SEL))objc_msgSend)((id)configurationClass, @selector(new));

    // One shared WebContent process for every tab: opening a tab otherwise spins up a fresh
    // process (and re-parses the injected script) each time, which is the slowest part of a
    // multi-tab page load on tvOS.
    static dispatch_once_t browserPoolOnce;
    static id browserSharedProcessPool = nil;
    dispatch_once(&browserPoolOnce, ^{
        Class poolClass = NSClassFromString(@"WKProcessPool");
        if (poolClass != Nil) {
            browserSharedProcessPool = ((id (*)(id, SEL))objc_msgSend)((id)poolClass, @selector(new));
        }
    });
    if (browserSharedProcessPool != nil) {
        SEL setProcessPoolSelector = NSSelectorFromString(@"setProcessPool:");
        if ([configuration respondsToSelector:setProcessPoolSelector]) {
            ((void (*)(id, SEL, id))objc_msgSend)(configuration, setProcessPoolSelector, browserSharedProcessPool);
            NSLog(@"[Perf] shared WKProcessPool installed for tab reuse");
        }
    }

    SEL allowsInlineMediaPlaybackSelector = NSSelectorFromString(@"setAllowsInlineMediaPlayback:");
    if (configuration != nil && [configuration respondsToSelector:allowsInlineMediaPlaybackSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(configuration, allowsInlineMediaPlaybackSelector, allowsInlineMediaPlayback);
    }
    BrowserConfigurePrivateMediaPreferences(configuration);
    BrowserConfigureMediaPlaybackPolicy(configuration);
    BrowserInstallFullscreenInterceptUserScript(configuration);
    BrowserInstallYouTubeCaptureUserScript(configuration);
    BrowserConfigureDefaultReferrer(configuration);

    id webViewObject = ((id (*)(id, SEL))objc_msgSend)((id)webViewClass, @selector(alloc));
    SEL initializer = NSSelectorFromString(@"initWithFrame:configuration:");
    webViewObject = ((id (*)(id, SEL, CGRect, id))objc_msgSend)(webViewObject, initializer, self.bounds, configuration);
    if (webViewObject == nil) {
        return;
    }

    self.runtimeWebView = webViewObject;
    UIView *runtimeView = (UIView *)webViewObject;
    runtimeView.frame = self.bounds;
    runtimeView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    runtimeView.backgroundColor = UIColor.blackColor;

    SEL navigationDelegateSelector = NSSelectorFromString(@"setNavigationDelegate:");
    if ([webViewObject respondsToSelector:navigationDelegateSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(webViewObject, navigationDelegateSelector, self);
    }

    SEL UIDelegateSelector = NSSelectorFromString(@"setUIDelegate:");
    if ([webViewObject respondsToSelector:UIDelegateSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(webViewObject, UIDelegateSelector, self);
    }

    [self addSubview:runtimeView];
    [self setUserAgent:userAgent];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    ((UIView *)self.runtimeWebView).frame = self.bounds;
    [self applyPageScalingIfNeeded];
}

- (void)setUserInteractionEnabled:(BOOL)userInteractionEnabled {
    [super setUserInteractionEnabled:userInteractionEnabled];

    UIView *runtimeView = (UIView *)self.runtimeWebView;
    runtimeView.userInteractionEnabled = userInteractionEnabled;

    UIScrollView *scrollView = [self scrollView];
    scrollView.userInteractionEnabled = userInteractionEnabled;
}

- (UIScrollView *)scrollView {
    SEL selector = NSSelectorFromString(@"scrollView");
    if (self.runtimeWebView == nil || ![self.runtimeWebView respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
}

- (NSURL *)currentURL {
    SEL selector = NSSelectorFromString(@"URL");
    if (self.runtimeWebView == nil || ![self.runtimeWebView respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
}

- (NSURLRequest *)request {
    NSURL *currentURL = [self currentURL];
    if (currentURL != nil) {
        return [NSURLRequest requestWithURL:currentURL];
    }
    return self.lastRequest;
}

- (NSString *)title {
    SEL selector = NSSelectorFromString(@"title");
    if (self.runtimeWebView == nil || ![self.runtimeWebView respondsToSelector:selector]) {
        return self.lastTitle;
    }
    NSString *title = ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    return title ?: self.lastTitle;
}

- (BOOL)canGoBack {
    SEL selector = NSSelectorFromString(@"canGoBack");
    return self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector] ? ((BOOL (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector) : NO;
}

- (BOOL)canGoForward {
    SEL selector = NSSelectorFromString(@"canGoForward");
    return self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector] ? ((BOOL (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector) : NO;
}

- (void)loadRequest:(NSURLRequest *)request {
    if (request == nil || self.runtimeWebView == nil) {
        return;
    }
    self.lastRequest = request;
    SEL selector = NSSelectorFromString(@"loadRequest:");
    if ([self.runtimeWebView respondsToSelector:selector]) {
        ((id (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, selector, request);
    }
}

- (void)reload {
    SEL selector = NSSelectorFromString(@"reload");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    }
}

- (void)goBack {
    SEL selector = NSSelectorFromString(@"goBack");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    }
}

- (void)goForward {
    SEL selector = NSSelectorFromString(@"goForward");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    }
}

- (NSString *)stringByEvaluatingJavaScriptFromString:(NSString *)script {
    if (script.length == 0 || self.runtimeWebView == nil) {
        return nil;
    }

    SEL selector = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    if (![self.runtimeWebView respondsToSelector:selector]) {
        return nil;
    }

    __block id evaluationResult = nil;
    __block NSError *evaluationError = nil;
    __block BOOL finished = NO;
    ((void (*)(id, SEL, id, id))objc_msgSend)(self.runtimeWebView, selector, script, ^(id result, NSError *error) {
        evaluationResult = result;
        evaluationError = error;
        finished = YES;
    });
    BrowserPumpRunLoopUntil(&finished);

    if (evaluationError != nil) {
        return nil;
    }
    return BrowserStringFromJavaScriptResult(evaluationResult);
}

- (void)pauseAllMediaPlayback {
    if (self.runtimeWebView == nil) {
        return;
    }

    // Prefer WebKit's internal media pause APIs when available.
    SEL pauseWithCompletionHandlerSelector = NSSelectorFromString(@"pauseAllMediaPlaybackWithCompletionHandler:");
    if ([self.runtimeWebView respondsToSelector:pauseWithCompletionHandlerSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, pauseWithCompletionHandlerSelector, nil);
    } else {
        SEL pauseSelector = NSSelectorFromString(@"pauseAllMediaPlayback:");
        if ([self.runtimeWebView respondsToSelector:pauseSelector]) {
            ((void (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, pauseSelector, nil);
        } else {
            SEL privatePauseSelector = NSSelectorFromString(@"_pauseAllMediaPlayback");
            if ([self.runtimeWebView respondsToSelector:privatePauseSelector]) {
                ((void (*)(id, SEL))objc_msgSend)(self.runtimeWebView, privatePauseSelector);
            }
        }
    }

    // JS fallback for page media elements and common iframe-based players.
    NSString *pauseScript =
        @"(function(){"
            "function safe(fn){ try { fn(); } catch (error) {} }"
            "var media = document.querySelectorAll('video,audio');"
            "for (var i = 0; i < media.length; i++) {"
                "var element = media[i];"
                "safe(function(){ element.pause(); });"
                "safe(function(){ element.autoplay = false; });"
                "safe(function(){ element.removeAttribute('autoplay'); });"
            "}"
            "var iframePlayers = document.querySelectorAll('iframe');"
            "for (var j = 0; j < iframePlayers.length; j++) {"
                "var frame = iframePlayers[j];"
                "var src = String(frame.src || '').toLowerCase();"
                "if (!src) { continue; }"
                "safe(function(){"
                    "if (src.indexOf('youtube.com') !== -1 || src.indexOf('youtube-nocookie.com') !== -1) {"
                        "frame.contentWindow.postMessage(JSON.stringify({event:'command',func:'pauseVideo',args:''}), '*');"
                    "}"
                "});"
                "safe(function(){"
                    "if (src.indexOf('vimeo.com') !== -1) {"
                        "frame.contentWindow.postMessage(JSON.stringify({method:'pause'}), '*');"
                    "}"
                "});"
            "}"
        "})();";
    [self stringByEvaluatingJavaScriptFromString:pauseScript];
}

- (NSString *)runtimeMediaPreferenceReport {
    if (self.runtimeWebView == nil) {
        return @"Runtime web view unavailable.";
    }

    NSArray<NSDictionary<NSString *, NSString *> *> *objectSelectors = @[
        @{@"label": @"WKWebView", @"selector": @""},
        @{@"label": @"Configuration", @"selector": @"configuration"},
        @{@"label": @"Configuration._preferences", @"selector": @"configuration._preferences"},
        @{@"label": @"Configuration.preferences", @"selector": @"configuration.preferences"},
        @{@"label": @"Configuration.defaultWebpagePreferences", @"selector": @"configuration.defaultWebpagePreferences"},
        @{@"label": @"Configuration.websiteDataStore", @"selector": @"configuration.websiteDataStore"},
        @{@"label": @"WKWebView._configuration", @"selector": @"_configuration"},
        @{@"label": @"WKWebView._page", @"selector": @"_page"},
    ];

    NSMutableDictionary<NSValue *, NSString *> *seenObjects = [NSMutableDictionary dictionary];
    NSMutableString *report = [NSMutableString string];

    for (NSDictionary<NSString *, NSString *> *entry in objectSelectors) {
        NSString *label = entry[@"label"] ?: @"Object";
        NSString *selectorPath = entry[@"selector"] ?: @"";
        id currentObject = self.runtimeWebView;

        if (selectorPath.length > 0) {
            NSArray<NSString *> *components = [selectorPath componentsSeparatedByString:@"."];
            for (NSString *component in components) {
                currentObject = BrowserObjectResultForGetter(currentObject, component);
                if (currentObject == nil) {
                    break;
                }
            }
        }

        if (currentObject == nil) {
            [report appendFormat:@"[%@] unavailable\n\n", label];
            continue;
        }

        NSValue *objectKey = [NSValue valueWithNonretainedObject:currentObject];
        NSString *previousLabel = seenObjects[objectKey];
        if (previousLabel != nil) {
            [report appendFormat:@"[%@] same object as %@ (%@)\n\n", label, previousLabel, NSStringFromClass([currentObject class])];
            continue;
        }
        seenObjects[objectKey] = label;

        NSArray<NSString *> *selectorNames = BrowserFilteredSelectorNamesForClass([currentObject class]);
        NSMutableArray<NSString *> *booleanLines = [NSMutableArray array];
        for (NSString *selectorName in selectorNames) {
            NSString *getterName = nil;
            if ([selectorName hasPrefix:@"set"] && [selectorName hasSuffix:@":"]) {
                getterName = BrowserGetterNameFromSetterName(selectorName);
            } else {
                getterName = selectorName;
            }

            NSString *valueDescription = BrowserBooleanValueDescriptionForObjectAndSelector(currentObject, getterName);
            if (valueDescription != nil) {
                [booleanLines addObject:[NSString stringWithFormat:@"%@ = %@", getterName, valueDescription]];
            }
        }

        [report appendFormat:@"[%@] %@\n", label, NSStringFromClass([currentObject class])];
        if (booleanLines.count > 0) {
            [report appendString:@"Boolean getters:\n"];
            for (NSString *line in booleanLines) {
                [report appendFormat:@"- %@\n", line];
            }
        } else {
            [report appendString:@"Boolean getters:\n- none resolved\n"];
        }

        [report appendString:@"Matching selectors:\n"];
        if (selectorNames.count == 0) {
            [report appendString:@"- none\n\n"];
            continue;
        }

        for (NSString *selectorName in selectorNames) {
            [report appendFormat:@"- %@\n", selectorName];
        }

        if ([label isEqualToString:@"Configuration.preferences"]) {
            NSArray<NSDictionary<NSString *, NSString *> *> *featureEntries = BrowserFeatureEntriesForPreferences(currentObject);
            [report appendString:@"Feature entries:\n"];
            if (featureEntries.count == 0) {
                [report appendString:@"- none\n"];
            } else {
                for (NSDictionary<NSString *, NSString *> *featureEntry in featureEntries) {
                    NSString *featureSource = featureEntry[@"source"] ?: @"features";
                    NSString *featureName = featureEntry[@"name"] ?: @"Unknown";
                    NSString *featureEnabled = featureEntry[@"enabled"] ?: @"unknown";
                    NSString *featureKey = featureEntry[@"key"];
                    if (featureKey.length > 0) {
                        [report appendFormat:@"- [%@] %@ (%@) = %@\n", featureSource, featureName, featureKey, featureEnabled];
                    } else {
                        [report appendFormat:@"- [%@] %@ = %@\n", featureSource, featureName, featureEnabled];
                    }
                }
            }
        }
        [report appendString:@"\n"];
    }

    return BrowserPreviewString(report, 24000);
}

- (void)installYouTubeRequestCaptureHook {
    [self stringByEvaluatingJavaScriptFromString:BrowserYouTubeRequestCaptureScript()];
}

// Reinstalls the pseudo fullscreen engine into the live document. Needed when the page was
// already loaded before the user script became active (restored tabs, cached BFCache pages).
- (void)installPseudoFullscreenEngineFallback {
    [self stringByEvaluatingJavaScriptFromString:BrowserFullscreenInterceptScript()];
}

- (void)setUserAgent:(NSString *)userAgent {
    _userAgent = [userAgent copy];
    SEL selector = NSSelectorFromString(@"setCustomUserAgent:");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, selector, _userAgent);
    }
}

- (void)setScalesPageToFit:(BOOL)scalesPageToFit {
    _scalesPageToFit = scalesPageToFit;
    [self applyPageScalingIfNeeded];
}

- (void)applyPageScalingIfNeeded {
    if (self.runtimeWebView == nil) {
        return;
    }

    UIScrollView *scrollView = [self scrollView];
    if (scrollView == nil || CGRectIsEmpty(scrollView.bounds)) {
        return;
    }

    CGFloat zoomValue = 1.0;
    if (self.scalesPageToFit) {
        CGFloat contentWidth = scrollView.contentSize.width;
        CGFloat boundsWidth = CGRectGetWidth(scrollView.bounds);
        if (contentWidth > 1.0 && boundsWidth > 1.0) {
            zoomValue = MIN(1.0, MAX(0.25, boundsWidth / contentWidth));
        }
    }

    SEL pageZoomSelector = NSSelectorFromString(@"setPageZoom:");
    if ([self.runtimeWebView respondsToSelector:pageZoomSelector]) {
        ((void (*)(id, SEL, double))objc_msgSend)(self.runtimeWebView, pageZoomSelector, zoomValue);
        return;
    }

    NSString *script = zoomValue == 1.0
        ? @"document.documentElement.style.zoom=''; document.body.style.zoom='';"
        : [NSString stringWithFormat:@"document.documentElement.style.zoom='%0.4f'; document.body.style.zoom='%0.4f';", zoomValue, zoomValue];
    [self stringByEvaluatingJavaScriptFromString:script];
}

- (void)webView:(id)webView didStartProvisionalNavigation:(id)navigation {
    self.loading = YES;
    if ([self.delegate respondsToSelector:@selector(webViewDidStartLoad:)]) {
        [self.delegate webViewDidStartLoad:self];
    }
}

- (void)webView:(id)webView didFinishNavigation:(id)navigation {
    self.loading = NO;
    self.lastTitle = [self title];
    self.lastRequest = [self request];
    [self installYouTubeRequestCaptureHook];
    [self applyPageScalingIfNeeded];
    if ([self.delegate respondsToSelector:@selector(webViewDidFinishLoad:)]) {
        [self.delegate webViewDidFinishLoad:self];
    }
}

- (void)webView:(id)webView didFailNavigation:(id)navigation withError:(NSError *)error {
    self.loading = NO;
    if ([self.delegate respondsToSelector:@selector(webView:didFailLoadWithError:)]) {
        [self.delegate webView:self didFailLoadWithError:error];
    }
}

- (void)webView:(id)webView didFailProvisionalNavigation:(id)navigation withError:(NSError *)error {
    self.loading = NO;
    if ([self.delegate respondsToSelector:@selector(webView:didFailLoadWithError:)]) {
        [self.delegate webView:self didFailLoadWithError:error];
    }
}

- (void)webViewWebContentProcessDidTerminate:(id)webView {
    self.loading = NO;
}

- (NSURLRequest *)requestFromNavigationAction:(id)navigationAction {
    if (navigationAction == nil) {
        return nil;
    }
    SEL requestSelector = NSSelectorFromString(@"request");
    if (![navigationAction respondsToSelector:requestSelector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(navigationAction, requestSelector);
}

- (NSInteger)navigationTypeFromNavigationAction:(id)navigationAction {
    if (navigationAction == nil) {
        return 0;
    }
    SEL navigationTypeSelector = NSSelectorFromString(@"navigationType");
    if (![navigationAction respondsToSelector:navigationTypeSelector]) {
        return 0;
    }
    return ((NSInteger (*)(id, SEL))objc_msgSend)(navigationAction, navigationTypeSelector);
}

- (void)webView:(id)webView decidePolicyForNavigationAction:(id)navigationAction decisionHandler:(void (^)(NSInteger policy))decisionHandler {
    NSURLRequest *request = [self requestFromNavigationAction:navigationAction];
    NSInteger navigationType = [self navigationTypeFromNavigationAction:navigationAction];
    BOOL isMainFrameRequest = YES;

    SEL targetFrameSelector = NSSelectorFromString(@"targetFrame");
    if ([navigationAction respondsToSelector:targetFrameSelector]) {
        id targetFrame = ((id (*)(id, SEL))objc_msgSend)(navigationAction, targetFrameSelector);
        SEL mainFrameSelector = NSSelectorFromString(@"isMainFrame");
        if (targetFrame != nil && [targetFrame respondsToSelector:mainFrameSelector]) {
            isMainFrameRequest = ((BOOL (*)(id, SEL))objc_msgSend)(targetFrame, mainFrameSelector);
        }
    }

    BOOL shouldAllow = YES;
    if ([self.delegate respondsToSelector:@selector(webView:shouldStartLoadWithRequest:navigationType:)]) {
        shouldAllow = [self.delegate webView:self shouldStartLoadWithRequest:request navigationType:navigationType];
    }

    if (shouldAllow && isMainFrameRequest && request != nil) {
        self.lastRequest = request;
    }

    if (decisionHandler != nil) {
        decisionHandler(shouldAllow ? 1 : 0);
    }
}

- (id)webView:(id)webView
createWebViewWithConfiguration:(id)configuration
forNavigationAction:(id)navigationAction
windowFeatures:(id)windowFeatures {
    (void)webView;
    (void)configuration;
    (void)windowFeatures;

    NSURLRequest *request = [self requestFromNavigationAction:navigationAction];
    NSInteger navigationType = [self navigationTypeFromNavigationAction:navigationAction];

    BOOL delegateHandlesNewTabRequests = [self.delegate respondsToSelector:@selector(webView:shouldCreateNewTabWithRequest:navigationType:)];
    BOOL handledInTab = NO;
    if (delegateHandlesNewTabRequests) {
        handledInTab = [self.delegate webView:self shouldCreateNewTabWithRequest:request navigationType:navigationType];
    }

    if (!delegateHandlesNewTabRequests && !handledInTab && request != nil) {
        BOOL shouldAllow = YES;
        if ([self.delegate respondsToSelector:@selector(webView:shouldStartLoadWithRequest:navigationType:)]) {
            shouldAllow = [self.delegate webView:self shouldStartLoadWithRequest:request navigationType:navigationType];
        }
        if (shouldAllow) {
            [self loadRequest:request];
        }
    }

    return nil;
}

+ (id)defaultWebsiteDataStore {
    BrowserEnsureWebKitRuntimeLoaded();
    Class dataStoreClass = NSClassFromString(kBrowserWebsiteDataStoreClassName);
    SEL selector = NSSelectorFromString(@"defaultDataStore");
    if (dataStoreClass == Nil || ![dataStoreClass respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)((id)dataStoreClass, selector);
}

+ (id)defaultCookieStore {
    id dataStore = [self defaultWebsiteDataStore];
    SEL selector = NSSelectorFromString(@"httpCookieStore");
    if (dataStore == nil || ![dataStore respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(dataStore, selector);
}

+ (NSArray<NSHTTPCookie *> *)allCookies {
    id cookieStore = [self defaultCookieStore];
    SEL selector = NSSelectorFromString(@"getAllCookies:");
    if (cookieStore == nil || ![cookieStore respondsToSelector:selector]) {
        return NSHTTPCookieStorage.sharedHTTPCookieStorage.cookies ?: @[];
    }

    __block NSArray<NSHTTPCookie *> *cookies = nil;
    __block BOOL finished = NO;
    ((void (*)(id, SEL, id))objc_msgSend)(cookieStore, selector, ^(NSArray<NSHTTPCookie *> *fetchedCookies) {
        cookies = fetchedCookies;
        finished = YES;
    });
    BrowserPumpRunLoopUntil(&finished);
    return cookies ?: @[];
}

+ (NSData *)cookieDataRepresentation {
    NSArray<NSHTTPCookie *> *cookies = [self allCookies];
    NSError *error = nil;
    NSData *cookieData = [NSKeyedArchiver archivedDataWithRootObject:cookies requiringSecureCoding:NO error:&error];
    return error == nil ? cookieData : nil;
}

+ (void)restoreCookiesFromData:(NSData *)cookieData {
    if (cookieData.length == 0) {
        return;
    }

    NSError *error = nil;
    NSSet *allowedClasses = [NSSet setWithObjects:[NSArray class], [NSHTTPCookie class], nil];
    NSArray<NSHTTPCookie *> *cookies = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowedClasses fromData:cookieData error:&error];
    if (![cookies isKindOfClass:[NSArray class]]) {
        return;
    }

    id cookieStore = [self defaultCookieStore];
    SEL selector = NSSelectorFromString(@"setCookie:completionHandler:");
    if (cookieStore == nil || ![cookieStore respondsToSelector:selector]) {
        for (NSHTTPCookie *cookie in cookies) {
            [NSHTTPCookieStorage.sharedHTTPCookieStorage setCookie:cookie];
        }
        return;
    }

    __block NSInteger remainingCount = cookies.count;
    __block BOOL finished = cookies.count == 0;
    for (NSHTTPCookie *cookie in cookies) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(cookieStore, selector, cookie, ^{
            remainingCount -= 1;
            finished = remainingCount == 0;
        });
    }
    BrowserPumpRunLoopUntil(&finished);
}

+ (NSSet<NSString *> *)allWebsiteDataTypes {
    Class dataStoreClass = NSClassFromString(kBrowserWebsiteDataStoreClassName);
    SEL selector = NSSelectorFromString(@"allWebsiteDataTypes");
    if (dataStoreClass == Nil || ![dataStoreClass respondsToSelector:selector]) {
        return [NSSet set];
    }
    return ((id (*)(id, SEL))objc_msgSend)((id)dataStoreClass, selector);
}

+ (void)removeWebsiteDataTypes:(NSSet<NSString *> *)websiteDataTypes completion:(void (^)(void))completion {
    id dataStore = [self defaultWebsiteDataStore];
    SEL selector = NSSelectorFromString(@"removeDataOfTypes:modifiedSince:completionHandler:");
    if (dataStore == nil || ![dataStore respondsToSelector:selector]) {
        if (completion != nil) {
            completion();
        }
        return;
    }

    NSDate *beginningOfTime = [NSDate dateWithTimeIntervalSince1970:0];
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(dataStore, selector, websiteDataTypes, beginningOfTime, ^{
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion();
            });
        }
    });
}

+ (void)clearCachedDataWithCompletion:(void (^)(void))completion {
    [[NSURLCache sharedURLCache] removeAllCachedResponses];

    NSMutableSet<NSString *> *websiteDataTypes = [[self allWebsiteDataTypes] mutableCopy];
    for (NSString *dataType in websiteDataTypes.allObjects) {
        if ([dataType.lowercaseString containsString:@"cookie"]) {
            [websiteDataTypes removeObject:dataType];
        }
    }

    [self removeWebsiteDataTypes:websiteDataTypes completion:completion];
}

+ (void)clearCookiesWithCompletion:(void (^)(void))completion {
    id cookieStore = [self defaultCookieStore];
    SEL getAllCookiesSelector = NSSelectorFromString(@"getAllCookies:");
    SEL deleteCookieSelector = NSSelectorFromString(@"deleteCookie:completionHandler:");
    if (cookieStore == nil || ![cookieStore respondsToSelector:getAllCookiesSelector] || ![cookieStore respondsToSelector:deleteCookieSelector]) {
        NSHTTPCookieStorage *storage = NSHTTPCookieStorage.sharedHTTPCookieStorage;
        for (NSHTTPCookie *cookie in storage.cookies) {
            [storage deleteCookie:cookie];
        }
        if (completion != nil) {
            completion();
        }
        return;
    }

    ((void (*)(id, SEL, id))objc_msgSend)(cookieStore, getAllCookiesSelector, ^(NSArray<NSHTTPCookie *> *cookies) {
        if (cookies.count == 0) {
            if (completion != nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion();
                });
            }
            return;
        }

        __block NSInteger remainingCount = cookies.count;
        for (NSHTTPCookie *cookie in cookies) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(cookieStore, deleteCookieSelector, cookie, ^{
                remainingCount -= 1;
                if (remainingCount == 0 && completion != nil) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion();
                    });
                }
            });
        }
    });
}

+ (void)resetWebsiteDataWithCompletion:(void (^)(void))completion {
    [[NSURLCache sharedURLCache] removeAllCachedResponses];
    [self removeWebsiteDataTypes:[self allWebsiteDataTypes] completion:completion];
}

@end
