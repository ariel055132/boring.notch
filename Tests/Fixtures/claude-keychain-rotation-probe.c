// Reads only a UUID-named disposable fixture, never a login/Claude item.
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int fixture_service(const char *path, char *service, size_t capacity) {
    struct passwd *user = getpwuid(getuid());
    if (!user) return 0;
    char prefix[4096];
    int count = snprintf(prefix, sizeof(prefix), "%s/Library/Keychains/boring-notch-rotation-fixture-", user->pw_dir);
    if (count < 0 || (size_t)count >= sizeof(prefix) || strncmp(path, prefix, (size_t)count)) return 0;
    const char *uuid = path + count;
    if (strlen(uuid) != 36 + strlen(".keychain") || strcmp(uuid + 36, ".keychain")) return 0;
    for (int i = 0; i < 36; i++) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (uuid[i] != '-') return 0;
        } else if (!strchr("0123456789abcdef", uuid[i])) return 0;
    }
    count = snprintf(service, capacity, "BoringNotch-rotation-fixture-%.*s", 36, uuid);
    return count > 0 && (size_t)count < capacity;
}

static void print_acl(SecKeychainRef keychain, const char *service) {
    const void *keys[] = {kSecClass, kSecAttrService, kSecAttrAccount, kSecReturnRef, kSecMatchSearchList};
    const void *search_values[] = {keychain};
    CFArrayRef search = CFArrayCreate(NULL, search_values, 1, &kCFTypeArrayCallBacks);
    CFStringRef service_name = CFStringCreateWithCString(NULL, service, kCFStringEncodingUTF8);
    const void *values[] = {kSecClassGenericPassword, service_name, CFSTR("fixture"), kCFBooleanTrue, search};
    CFDictionaryRef query = CFDictionaryCreate(NULL, keys, values, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFTypeRef item = NULL;
    OSStatus status = SecItemCopyMatching(query, &item);
    printf("item_ref_status=%d\n", (int)status);
    if (status == errSecSuccess) {
        SecAccessRef access = NULL;
        status = SecKeychainItemCopyAccess((SecKeychainItemRef)item, &access);
        printf("access_status=%d\n", (int)status);
        if (status == errSecSuccess) {
            CFArrayRef acls = NULL;
            status = SecAccessCopyACLList(access, &acls);
            printf("acl_status=%d\n", (int)status);
            if (status == errSecSuccess) {
                for (CFIndex i = 0; i < CFArrayGetCount(acls); i++) {
                    SecACLRef acl = (SecACLRef)CFArrayGetValueAtIndex(acls, i);
                    CFArrayRef authorizations = SecACLCopyAuthorizations(acl);
                    CFArrayRef apps = NULL;
                    CFStringRef description = NULL;
                    SecKeychainPromptSelector prompt = 0;
                    status = SecACLCopyContents(acl, &apps, &description, &prompt);
                    if (status == errSecSuccess && authorizations) {
                        CFRange range = CFRangeMake(0, CFArrayGetCount(authorizations));
                        if (CFArrayContainsValue(authorizations, range, CFSTR("ACLAuthorizationPartitionID")) && description) {
                            char hex[65536];
                            if (CFStringGetCString(description, hex, sizeof(hex), kCFStringEncodingUTF8)) {
                                printf("partition_hex=%s\n", hex);
                            }
                        }
                        if (CFArrayContainsValue(authorizations, range, CFSTR("ACLAuthorizationDecrypt")) && apps) {
                            for (CFIndex j = 0; j < CFArrayGetCount(apps); j++) {
                                CFDataRef data = NULL;
                                status = SecTrustedApplicationCopyData((SecTrustedApplicationRef)CFArrayGetValueAtIndex(apps, j), &data);
                                if (status == errSecSuccess && data) {
                                    const UInt8 *bytes = CFDataGetBytePtr(data);
                                    CFIndex length = CFDataGetLength(data);
                                    printf("trusted_app=%.*s\n", (int)strnlen((const char *)bytes, (size_t)length), (const char *)bytes);
                                    CFRelease(data);
                                }
                            }
                        }
                    }
                    if (authorizations) CFRelease(authorizations);
                    if (apps) CFRelease(apps);
                    if (description) CFRelease(description);
                }
                CFRelease(acls);
            }
            CFRelease(access);
        }
        CFRelease(item);
    }
    CFRelease(query);
    CFRelease(service_name);
    CFRelease(search);
}

int main(int argc, char **argv) {
    char service[128];
    if (argc != 4 || !fixture_service(argv[2], service, sizeof(service))) return 64;
    if (strcmp(argv[1], "read") && strcmp(argv[1], "status") && strcmp(argv[1], "acl")) return 64;
    // The fixture must never show a Keychain prompt, including the denied read.
    OSStatus status = SecKeychainSetUserInteractionAllowed(false);
    if (status != errSecSuccess) { printf("disable_ui_status=%d\n", (int)status); return 1; }
    SecKeychainRef keychain = NULL;
    status = SecKeychainOpen(argv[2], &keychain);
    if (status != errSecSuccess) { printf("open_status=%d\n", (int)status); return 1; }
    SecKeychainStatus flags = 0;
    status = SecKeychainGetStatus(keychain, &flags);
    printf("keychain_status=%d\nunlocked=%d\n", (int)status, (flags & kSecUnlockStateStatus) != 0);
    if (!strcmp(argv[1], "acl")) {
        print_acl(keychain, service);
    } else if (!strcmp(argv[1], "read")) {
        UInt32 length = 0;
        void *data = NULL;
        status = SecKeychainFindGenericPassword(keychain, (UInt32)strlen(service), service, 7, "fixture", &length, &data, NULL);
        printf("read_status=%d\nmatches_expected=%d\n", (int)status,
               status == errSecSuccess && length == strlen(argv[3]) && !memcmp(data, argv[3], length));
        if (data) SecKeychainItemFreeContent(NULL, data);
    }
    CFRelease(keychain);
    return 0;
}
