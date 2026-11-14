#import <CloudKit/CloudKit.h>

// A re-signed app may no longer have the original CloudKit container. CloudKit
// raises an Objective-C exception in that case; Swift's do/catch cannot catch it.
CKContainer * _Nullable CloudDataDefaultContainer(void);
