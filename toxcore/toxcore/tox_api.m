#include "tox.h"

#include <stdlib.h>
#include <string.h>

#define SET_ERROR_PARAMETER(param, x) {if(param) {*param = x;}}


#define CONST_FUNCTION(lowercase, uppercase) \
uint32_t tox_##lowercase(void) \
{ \
    return TOX_##uppercase; \
}

CONST_FUNCTION(version_major, VERSION_MAJOR)
CONST_FUNCTION(version_minor, VERSION_MINOR)
CONST_FUNCTION(version_patch, VERSION_PATCH)
CONST_FUNCTION(public_key_size, PUBLIC_KEY_SIZE)
CONST_FUNCTION(secret_key_size, SECRET_KEY_SIZE)
CONST_FUNCTION(address_size, ADDRESS_SIZE)
CONST_FUNCTION(max_name_length, MAX_NAME_LENGTH)
CONST_FUNCTION(max_status_message_length, MAX_STATUS_MESSAGE_LENGTH)
CONST_FUNCTION(max_friend_request_length, MAX_FRIEND_REQUEST_LENGTH)
CONST_FUNCTION(max_message_length, MAX_MESSAGE_LENGTH)
CONST_FUNCTION(max_custom_packet_size, MAX_CUSTOM_PACKET_SIZE)
CONST_FUNCTION(hash_length, HASH_LENGTH)
CONST_FUNCTION(file_id_length, FILE_ID_LENGTH)
CONST_FUNCTION(max_filename_length, MAX_FILENAME_LENGTH)


#define ACCESSORS(type, ns, name) \
type tox_options_get_##ns##name(const struct Tox_Options *options) \
{ \
    return options->ns##name; \
} \
void tox_options_set_##ns##name(struct Tox_Options *options, type name) \
{ \
    options->ns##name = name; \
}

ACCESSORS(bool, , ipv6_enabled)
ACCESSORS(bool, , udp_enabled)
ACCESSORS(TOX_PROXY_TYPE, proxy_ , type)
ACCESSORS(const char *, proxy_ , host)
ACCESSORS(uint16_t, proxy_ , port)
ACCESSORS(uint16_t, , start_port)
ACCESSORS(uint16_t, , end_port)
ACCESSORS(uint16_t, , tcp_port)
ACCESSORS(bool, , hole_punching_enabled)
ACCESSORS(TOX_SAVEDATA_TYPE, savedata_, type)
ACCESSORS(size_t, savedata_, length)
ACCESSORS(tox_log_cb *, log_, callback)
ACCESSORS(void *, log_, user_data)
ACCESSORS(bool, , local_discovery_enabled)

const uint8_t *tox_options_get_savedata_data(const struct Tox_Options *options)
{
    return options->savedata_data;
}

void tox_options_set_savedata_data(struct Tox_Options *options, const uint8_t *data, size_t length)
{
    options->savedata_data = data;
    options->savedata_length = length;
}

void tox_options_default(struct Tox_Options *options)
{
    if (options) {
        struct Tox_Options default_options = { 0 };
        *options = default_options;
        tox_options_set_ipv6_enabled(options, true);
        tox_options_set_udp_enabled(options, true);
        tox_options_set_proxy_type(options, TOX_PROXY_TYPE_NONE);
        tox_options_set_hole_punching_enabled(options, true);
        tox_options_set_local_discovery_enabled(options, true);
    }
}

struct Tox_Options *tox_options_new(TOX_ERR_OPTIONS_NEW *error)
{
    struct Tox_Options *options = (struct Tox_Options *)malloc(sizeof(struct Tox_Options));

    if (options) {
        tox_options_default(options);
        SET_ERROR_PARAMETER(error, TOX_ERR_OPTIONS_NEW_OK);
        return options;
    }

    SET_ERROR_PARAMETER(error, TOX_ERR_OPTIONS_NEW_MALLOC);
    return NULL;
}

void tox_options_free(struct Tox_Options *options)
{
    free(options);
}
