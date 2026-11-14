#import <Foundation/Foundation.h>
#import <CloudKit/CloudKit.h>
#import <objc/runtime.h>
#import <CloudDataSupport/CloudDataSupport.h>

static CKContainer *marker;

static CKContainer *availableContainer(id object, SEL selector) {
    return marker;
}

static CKContainer *unavailableContainer(id object, SEL selector) {
    [NSException raise:NSInvalidArgumentException format:@"Missing CloudKit entitlement after re-signing"];
    return nil;
}

int main(void) {
    @autoreleasepool {
        Method method = class_getClassMethod([CKContainer class], @selector(defaultContainer));
        marker = (CKContainer *)[NSObject new];
        IMP original = method_setImplementation(method, (IMP)availableContainer);
        NSCAssert(CloudDataDefaultContainer() == marker, @"A valid container must be preserved");
        method_setImplementation(method, (IMP)unavailableContainer);
        NSCAssert(CloudDataDefaultContainer() == nil, @"An Objective-C CloudKit exception must not escape into Swift");
        method_setImplementation(method, original);
        NSLog(@"CloudData real bridge: valid container and entitlement exception regression passed");
    }
    return 0;
}
