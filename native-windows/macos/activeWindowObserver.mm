#import "activeWindowObserver.h"
#include <iostream>

Napi::ThreadSafeFunction activeWindowChangedCallback;
ActiveWindowObserver *windowObserver;

auto napiCallback = [](Napi::Env env, Napi::Function jsCallback, std::string* data) {
    jsCallback.Call({Napi::String::New(env, *data)});

    delete data;
};

void windowChangeCallback(AXObserverRef observer, AXUIElementRef element, CFStringRef notificationName, void *refCon) {
    if (CFStringCompare(notificationName, kAXMainWindowChangedNotification, 0) == kCFCompareEqualTo) {
        NSTimeInterval delayInMSec = 30;
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInMSec * NSEC_PER_MSEC));
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            NSLog(@"mainWindowChanged");
            [(__bridge ActiveWindowObserver*)(refCon) getActiveWindow];
        });
    }
}

@implementation ActiveWindowObserver {
    NSNumber *processId;
    AXObserverRef observer;
}

- (void) dealloc
{
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [super dealloc];
}

- (id) init
{
    self = [super init];
    if (!self) return nil;

    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(receiveAppChangeNotification:) name:NSWorkspaceDidActivateApplicationNotification object:nil];

    return self;
}

- (void) receiveAppChangeNotification:(NSNotification *) notification
{
    [self removeWindowObserver];

    int currentAppPid = [NSProcessInfo processInfo].processIdentifier;
    NSDictionary<NSString*, NSRunningApplication*> *userInfo = [notification userInfo];
    NSNumber *selectedProcessId = [userInfo valueForKeyPath:@"NSWorkspaceApplicationKey.processIdentifier"];

    if (processId != nil && selectedProcessId.intValue == currentAppPid) {
        return;
    }

    processId = selectedProcessId;

    [self getActiveWindow];

    AXUIElementRef appElem = AXUIElementCreateApplication(processId.intValue);
    AXError createResult = AXObserverCreate(processId.intValue, windowChangeCallback, &observer);

    if (createResult != kAXErrorSuccess) {
        NSLog(@"Copy or create result failed");
        return;
    }

    AXObserverAddNotification(observer, appElem, kAXMainWindowChangedNotification, (__bridge void *)(self));
    CFRunLoopAddSource([[NSRunLoop currentRunLoop] getCFRunLoop], AXObserverGetRunLoopSource(observer), kCFRunLoopDefaultMode);
    NSLog(@"Observers added");
}

- (void) getActiveWindow
{
    CFArrayRef windowsRef = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    NSArray<NSDictionary*> *windowsArray = (NSArray *)CFBridgingRelease(windowsRef);
    NSPredicate *pIdPredicate = [NSPredicate predicateWithFormat:@"kCGWindowOwnerPID == %@ && kCGWindowLayer == 0", processId];
    NSArray *filteredWindows = [windowsArray filteredArrayUsingPredicate:pIdPredicate];
    NSDictionary *activeWindow = filteredWindows.count > 0 ? filteredWindows.firstObject : Nil;

    if (activeWindow == nil) {
        return;
    }

    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:activeWindow options:NSJSONWritingPrettyPrinted error:&error];

    if (!jsonData) {
        NSLog(@"Error converting NSDictionary to JSON: %@", error.localizedDescription);
        return;
    }

    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSLog(@"%@ activeWindow", jsonString);

    // JSON 문자열을 C++ 함수로 전달
    const char *cJsonString = [jsonString UTF8String];
    activeWindowChangedCallback.BlockingCall(new std::string(cJsonString), napiCallback);
}

- (void) removeWindowObserver
{
    if (observer != Nil) {
        CFRunLoopRemoveSource([[NSRunLoop currentRunLoop] getCFRunLoop], AXObserverGetRunLoopSource(observer), kCFRunLoopDefaultMode);
        CFRelease(observer);
        observer = Nil;
    }
}

- (void) cleanUp
{
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [self removeWindowObserver];
}
@end

void initActiveWindowObserver(Napi::Env env, Napi::Function windowCallback) {
    activeWindowChangedCallback = Napi::ThreadSafeFunction::New(env, windowCallback, "ActiveWindowChanged", 0, 1);
    windowObserver = [[ActiveWindowObserver alloc] init];
}

void stopActiveWindowObserver(Napi::Env env) {
    [windowObserver cleanUp];
    windowObserver = Nil;
    activeWindowChangedCallback.Abort();
    activeWindowChangedCallback = Nil;
}