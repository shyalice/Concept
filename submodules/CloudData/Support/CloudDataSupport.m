#import <CloudDataSupport/CloudDataSupport.h>

CKContainer * _Nullable CloudDataDefaultContainer(void) {
    @try {
        return [CKContainer defaultContainer];
    } @catch (NSException *exception) {
        // This is an optional emergency datacenter source. The normal network
        // bootstrap remains available without access to an iCloud container.
        return nil;
    }
}
