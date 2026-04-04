#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <QuickLook/QuickLook.h>

OSStatus GenerateThumbnailForURL(void *thisInterface, QLThumbnailRequestRef thumbnail, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options, CGSize maxSize);
void CancelThumbnailGeneration(void *thisInterface, QLThumbnailRequestRef thumbnail);
OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options);
void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview);

// Must match CFPlugInFactories UUID in Info.plist
#define PLUGIN_FACTORY_UUID CFUUIDGetConstantUUIDWithBytes(NULL, \
    0x64, 0xA5, 0x76, 0x6B, 0xB2, 0x11, 0x44, 0xCB, \
    0x83, 0xEB, 0x9E, 0x6B, 0x87, 0xAD, 0xAF, 0x80)

typedef struct {
    QLGeneratorInterfaceStruct *_interface;
    CFUUIDRef _factoryID;
    UInt32 _refCount;
} OEQLPluginType;

static HRESULT myQueryInterface(void *thisInterface, REFIID iid, LPVOID *ppv) {
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, iid);
    if(CFEqual(requested, kQLGeneratorCallbacksInterfaceID) || CFEqual(requested, IUnknownUUID)) {
        ((OEQLPluginType *)thisInterface)->_interface->AddRef(thisInterface);
        *ppv = thisInterface;
        CFRelease(requested);
        return S_OK;
    }
    *ppv = NULL;
    CFRelease(requested);
    return E_NOINTERFACE;
}

static ULONG myAddRef(void *thisInterface) {
    return ++((OEQLPluginType *)thisInterface)->_refCount;
}

static ULONG myRelease(void *thisInterface) {
    OEQLPluginType *instance = (OEQLPluginType *)thisInterface;
    if(--instance->_refCount == 0) {
        CFPlugInRemoveInstanceForFactory(instance->_factoryID);
        CFRelease(instance->_factoryID);
        free(instance->_interface);
        free(instance);
        return 0;
    }
    return instance->_refCount;
}

static QLGeneratorInterfaceStruct gInterfaceVtbl = {
    NULL,
    myQueryInterface,
    myAddRef,
    myRelease,
    GenerateThumbnailForURL,
    CancelThumbnailGeneration,
    GeneratePreviewForURL,
    CancelPreviewGeneration
};

void *QuickLookGeneratorPluginFactory(CFAllocatorRef allocator, CFUUIDRef typeID) {
    if(!CFEqual(typeID, kQLGeneratorTypeID))
        return NULL;

    OEQLPluginType *instance = malloc(sizeof(OEQLPluginType));
    instance->_interface = malloc(sizeof(QLGeneratorInterfaceStruct));
    *instance->_interface = gInterfaceVtbl;
    instance->_factoryID = CFRetain(PLUGIN_FACTORY_UUID);
    instance->_refCount = 1;

    CFPlugInAddInstanceForFactory(instance->_factoryID);

    return instance;
}
