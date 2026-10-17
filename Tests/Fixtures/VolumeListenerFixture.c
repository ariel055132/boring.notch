#include "VolumeListenerFixture.h"
#include <Block.h>
#include <assert.h>
#include <dispatch/dispatch.h>
#include <stdlib.h>

// Test executable only: these definitions satisfy the production manager's
// CoreAudio calls. Real hardware is never read or written. State and registration
// are accessed on the main queue; background delivery captures immutable values.
static bool usesMasterVolume;
static AudioObjectID currentDevice = 1;
static Float32 currentVolume = 0.25f;
static UInt32 currentMute;
static UInt32 listenerCount;
static struct Listener {
    AudioObjectPropertyAddress address;
    dispatch_queue_t queue;
    AudioObjectPropertyListenerBlock callback;
} listeners[8];

void BNConfigureAudioFixture(bool master) { usesMasterVolume = master; }
void BNSetAudioFixtureState(AudioObjectID device, Float32 volume, UInt32 mute) {
    currentDevice = device;
    currentVolume = volume;
    currentMute = mute;
}
UInt32 BNAudioListenerCount(void) { return listenerCount; }
UInt32 BNVolumeListenerCount(void) {
    UInt32 count = 0;
    for (UInt32 i = 0; i < listenerCount; i++) {
        if (listeners[i].address.mSelector == kAudioDevicePropertyVolumeScalar) count++;
    }
    return count;
}

bool BNNotifyAudioFixture(AudioObjectPropertySelector selector, AudioObjectPropertyElement element) {
    for (UInt32 i = 0; i < listenerCount; i++) {
        const struct Listener listener = listeners[i];
        if (listener.address.mSelector != selector || listener.address.mElement != element) continue;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            dispatch_assert_queue_not(dispatch_get_main_queue());
            dispatch_block_t delivery = ^{
                AudioObjectPropertyAddress address = listener.address;
                listener.callback(1, &address);
            };
            if (listener.queue) dispatch_async(listener.queue, delivery);
            else delivery(); // CoreAudio's documented behavior for a NULL queue.
        });
        return true;
    }
    return false;
}

OSStatus AudioObjectAddPropertyListenerBlock(AudioObjectID object,
    const AudioObjectPropertyAddress *address, dispatch_queue_t queue,
    AudioObjectPropertyListenerBlock callback) {
    assert(listenerCount < 8);
    if (queue) dispatch_retain(queue);
    listeners[listenerCount++] = (struct Listener){*address, queue, Block_copy(callback)};
    return noErr;
}

Boolean AudioObjectHasProperty(AudioObjectID object, const AudioObjectPropertyAddress *address) {
    if (address->mSelector == kAudioDevicePropertyMute) return true;
    if (address->mSelector != kAudioDevicePropertyVolumeScalar) return false;
    return usesMasterVolume ? address->mElement == kAudioObjectPropertyElementMain
                            : address->mElement == 1 || address->mElement == 2;
}

OSStatus AudioObjectGetPropertyDataSize(AudioObjectID object,
    const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
    const void *qualifier, UInt32 *size) {
    *size = sizeof(UInt32);
    return noErr;
}

OSStatus AudioObjectGetPropertyData(AudioObjectID object,
    const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
    const void *qualifier, UInt32 *size, void *data) {
    switch (address->mSelector) {
        case kAudioHardwarePropertyDefaultOutputDevice:
            *(AudioObjectID *)data = currentDevice;
            break;
        case kAudioDevicePropertyVolumeScalar:
            if (object != currentDevice) return kAudioHardwareBadObjectError;
            *(Float32 *)data = currentVolume;
            break;
        case kAudioDevicePropertyMute:
            if (object != currentDevice) return kAudioHardwareBadObjectError;
            *(UInt32 *)data = currentMute;
            break;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
    return noErr;
}

OSStatus AudioObjectSetPropertyData(AudioObjectID object,
    const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
    const void *qualifier, UInt32 size, const void *data) {
    abort(); // Listener checks must not write audio properties.
}
