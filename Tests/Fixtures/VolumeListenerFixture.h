#pragma once

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>

void BNConfigureAudioFixture(bool usesMasterVolume);
void BNSetAudioFixtureState(AudioObjectID deviceID, Float32 volume, UInt32 muted);
UInt32 BNAudioListenerCount(void);
UInt32 BNVolumeListenerCount(void);
bool BNNotifyAudioFixture(AudioObjectPropertySelector selector, AudioObjectPropertyElement element);
