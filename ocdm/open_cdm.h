#ifndef FOTONE_OPEN_CDM_H
#define FOTONE_OPEN_CDM_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct OpenCDMSystem;
struct OpenCDMSession;

typedef enum {
    ERROR_NONE = 0,
    ERROR_UNKNOWN = 1,
    ERROR_MORE_DATA_AVAILBALE = 2,
    ERROR_INTERFACE_NOT_IMPLEMENTED = 3,
    ERROR_BUFFER_TOO_SMALL = 4,
    ERROR_INVALID_ACCESSOR = 0x80000001,
    ERROR_KEYSYSTEM_NOT_SUPPORTED = 0x80000002,
    ERROR_INVALID_SESSION = 0x80000003,
    ERROR_INVALID_DECRYPT_BUFFER = 0x80000004,
    ERROR_OUT_OF_MEMORY = 0x80000005,
    ERROR_METHOD_NOT_IMPLEMENTED = 0x80000006,
    ERROR_BUSY_CANNOT_INITIALIZE = 0x80000007,
    ERROR_FAIL = 0x80004005,
    ERROR_INVALID_ARG = 0x80070057
} OpenCDMError;

typedef enum {
    Usable = 0,
    Expired,
    Released,
    OutputRestricted,
    OutputRestrictedHDCP22,
    OutputDownscaled,
    StatusPending,
    InternalError,
    HWError
} KeyStatus;

typedef enum {
    Temporary = 0,
    PersistentUsageRecord,
    PersistentLicense
} LicenseType;

typedef struct {
    void (*process_challenge_callback)(struct OpenCDMSession *session, void *user_data, const char url[], const uint8_t challenge[], const uint16_t challenge_length);
    void (*key_update_callback)(struct OpenCDMSession *session, void *user_data, const uint8_t key_id[], const uint8_t length);
    void (*error_message_callback)(struct OpenCDMSession *session, void *user_data, const char message[]);
    void (*keys_updated_callback)(const struct OpenCDMSession *session, void *user_data);
} OpenCDMSessionCallbacks;

OpenCDMError opencdm_is_type_supported(const char key_system[], const char mime_type[]);

struct OpenCDMSystem *opencdm_create_system(const char key_system[]);
OpenCDMError opencdm_destruct_system(struct OpenCDMSystem *system);
bool opencdm_system_supports_server_certificate(struct OpenCDMSystem *system);
OpenCDMError opencdm_system_set_server_certificate(struct OpenCDMSystem *system, const uint8_t server_certificate[], uint32_t length);

OpenCDMError opencdm_construct_session(struct OpenCDMSystem *system, const LicenseType license_type, const char init_data_type[],
                                       const uint8_t init_data[], const uint16_t init_data_length, const uint8_t cdm_data[],
                                       const uint16_t cdm_data_length, OpenCDMSessionCallbacks *callbacks, void *user_data,
                                       struct OpenCDMSession **session);
struct OpenCDMSession *opencdm_get_system_session(struct OpenCDMSystem *system, const uint8_t key_id[], const uint8_t length,
                                                  const uint32_t wait_time);
OpenCDMError opencdm_destruct_session(struct OpenCDMSession *session);
const char *opencdm_session_id(const struct OpenCDMSession *session);
KeyStatus opencdm_session_status(const struct OpenCDMSession *session, const uint8_t key_id[], const uint8_t length);
OpenCDMError opencdm_session_update(struct OpenCDMSession *session, const uint8_t key_message[], uint32_t length);
OpenCDMError opencdm_session_load(struct OpenCDMSession *session);
OpenCDMError opencdm_session_remove(struct OpenCDMSession *session);
OpenCDMError opencdm_session_close(struct OpenCDMSession *session);

#ifdef __cplusplus
}
#endif

#endif
