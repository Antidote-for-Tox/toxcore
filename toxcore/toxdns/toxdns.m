/* toxdns.c
 *
 * Tox secure username DNS toxid resolving functions.
 *
 *  Copyright (C) 2013 Tox project All Rights Reserved.
 *
 *  This file is part of Tox.
 *
 *  Tox is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  Tox is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with Tox.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "../toxcore/Messenger.h"
#include "../toxcore/logger.h"
#include "toxdns.h"

static const char base32[32] = {
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm',
    'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
    '0', '1', '2', '3', '4', '5',
};

#define _encode(a, b, c) \
{ \
    uint8_t _i = 0; \
    while (_i != c) { \
        *a++ = base32[((b[0] >> bits) | (b[1] << (8 - bits))) & 0x1F]; \
        bits += 5; \
        if(bits >= 8) { \
            bits -= 8; \
            b++; \
            _i++; \
        } \
    } \
}

typedef struct {
    uint8_t temp_pk[CRYPTO_PUBLIC_KEY_SIZE];
    uint8_t temp_sk[CRYPTO_SECRET_KEY_SIZE];
    uint8_t server_public_key[CRYPTO_PUBLIC_KEY_SIZE];
    uint8_t shared_key[CRYPTO_SYMMETRIC_KEY_SIZE];
    uint32_t nonce;
    uint32_t nonce_start;
} DNS_Object;

static void dns_new_temp_keys(DNS_Object *d)
{
    d->nonce = d->nonce_start = random_int();
    crypto_new_keypair(d->temp_pk, d->temp_sk);
    encrypt_precompute(d->server_public_key, d->temp_sk, d->shared_key);
}

/* Create a new tox_dns3 object for server with server_public_key.
 *
 * return Null on failure.
 * return pointer object on success.
 */
void *tox_dns3_new(uint8_t *server_public_key)
{
    DNS_Object *d = (DNS_Object *)malloc(sizeof(DNS_Object));

    if (d == NULL) {
        return NULL;
    }

    memcpy(d->server_public_key, server_public_key, CRYPTO_PUBLIC_KEY_SIZE);
    dns_new_temp_keys(d);
    return d;
}

/* Destroy the tox dns3 object.
 */
void tox_dns3_kill(void *dns3_object)
{
    memset(dns3_object, 0, sizeof(DNS_Object));
    free(dns3_object);
}

/* Generate a dns3 string of string_max_len used to query the dns server referred to by to
 * dns3_object for a tox id registered to user with name of name_len.
 *
 * the uint32_t pointed by request_id will be set to the request id which must be passed to
 * tox_decrypt_dns3_TXT() to correctly decode the response.
 *
 * This is what the string returned looks like:
 * 4haaaaipr1o3mz0bxweox541airydbovqlbju51mb4p0ebxq.rlqdj4kkisbep2ks3fj2nvtmk4daduqiueabmexqva1jc
 *
 * returns length of string on success.
 * returns -1 on failure.
 */
int tox_generate_dns3_string(void *dns3_object, uint8_t *string, uint16_t string_max_len, uint32_t *request_id,
                             uint8_t *name, uint8_t name_len)
{
#define DOT_INTERVAL (6 * 5)
    int base = (sizeof(uint32_t) + CRYPTO_PUBLIC_KEY_SIZE + name_len + CRYPTO_MAC_SIZE);
    int end_len = ((base * 8) / 5) + (base / DOT_INTERVAL) + !!(base % 5);
    end_len -= !(base % DOT_INTERVAL);

    if (end_len > string_max_len) {
        return -1;
    }

    DNS_Object *d = (DNS_Object *)dns3_object;
    uint8_t buffer[1024];
    uint8_t nonce[CRYPTO_NONCE_SIZE] = {0};
    memcpy(nonce, &d->nonce, sizeof(uint32_t));
    memcpy(buffer, &d->nonce, sizeof(uint32_t));
    memcpy(buffer + sizeof(uint32_t), d->temp_pk, CRYPTO_PUBLIC_KEY_SIZE);
    int len = encrypt_data_symmetric(d->shared_key, nonce, name, name_len,
                                     buffer + sizeof(uint32_t) + CRYPTO_PUBLIC_KEY_SIZE);

    if (len == -1) {
        return -1;
    }

    int total_len = len + sizeof(uint32_t) + CRYPTO_PUBLIC_KEY_SIZE;
    uint8_t *buff = buffer, *old_str = string;
    buffer[total_len] = 0;
    uint8_t bits = 0;
    int i;

    for (i = !(total_len % DOT_INTERVAL); i < (total_len / DOT_INTERVAL); ++i) {
        _encode(string, buff, DOT_INTERVAL);
        *string = '.';
        ++string;
    }

    int left = total_len - (buff - buffer);
    _encode(string, buff, left);
#undef DOT_INTERVAL
    *request_id = d->nonce;
    ++d->nonce;

    if (d->nonce == d->nonce_start) {
        dns_new_temp_keys(d);
    }

    if (end_len != string - old_str) {
        // TODO(iphydf): This currently has no access to a logger.
        LOGGER_ERROR(NULL, "tox_generate_dns3_string Fail, %u != %lu\n", end_len, string - old_str);
        return -1;
    }

    return string - old_str;
}


static int decode(uint8_t *dest, uint8_t *src)
{
    uint8_t *p = src, *op = dest, bits = 0;
    *op = 0;

    while (*p) {
        uint8_t ch = *p++;

        if ('A' <= ch && ch <= 'Z') {
            ch = ch - 'A';
        } else if ('a' <= ch && ch <= 'z') {
            ch = ch - 'a';
        } else if ('0' <= ch && ch <= '5') {
            ch = ch - '0' + 26;
        } else {
            return - 1;
        }

        *op |= (ch << bits);
        bits += 5;

        if (bits >= 8) {
            bits -= 8;
            ++op;
            *op = (ch >> (5 - bits));
        }
    }

    return op - dest;
}

/* Decode and decrypt the id_record returned of length id_record_len into
 * tox_id (needs to be at least TOX_FRIEND_ADDRESS_SIZE).
 *
 * request_id is the request id given by tox_generate_dns3_string() when creating the request.
 *
 * the id_record passed to this function should look somewhat like this:
 * 2vgcxuycbuctvauik3plsv3d3aadv4zfjfhi3thaizwxinelrvigchv0ah3qjcsx5qhmaksb2lv2hm5cwbtx0yp
 *
 * returns -1 on failure.
 * returns 0 on success.
 *
 */
int tox_decrypt_dns3_TXT(void *dns3_object, uint8_t *tox_id, uint8_t *id_record, uint32_t id_record_len,
                         uint32_t request_id)
{
    DNS_Object *d = (DNS_Object *)dns3_object;

    if (id_record_len != 87) {
        return -1;
    }

#if 0

    if (id_record_len > 255 || id_record_len <= (sizeof(uint32_t) + CRYPTO_MAC_SIZE)) {
        return -1;
    }

#endif

    uint8_t id_record_null[id_record_len + 1];
    memcpy(id_record_null, id_record, id_record_len);
    id_record_null[id_record_len] = 0;
    uint8_t data[id_record_len];
    int length = decode(data, id_record_null);

    if (length == -1) {
        return -1;
    }

    uint8_t nonce[CRYPTO_NONCE_SIZE] = {0};
    memcpy(nonce, &request_id, sizeof(uint32_t));
    nonce[sizeof(uint32_t)] = 1;
    int len = decrypt_data_symmetric(d->shared_key, nonce, data, length, tox_id);

    if (len != FRIEND_ADDRESS_SIZE) {
        return -1;
    }

    return 0;
}
