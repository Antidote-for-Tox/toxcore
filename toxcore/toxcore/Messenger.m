/*
 * An implementation of a simple text chat only messenger on the tox network core.
 */

/*
 * Copyright © 2016-2017 The TokTok team.
 * Copyright © 2013 Tox project.
 *
 * This file is part of Tox, the free peer to peer instant messenger.
 *
 * Tox is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Tox is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Tox.  If not, see <http://www.gnu.org/licenses/>.
 */
#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "Messenger.h"

#include "logger.h"
#include "network.h"
#include "util.h"

#include <assert.h>

static int write_cryptpacket_id(const Messenger *m, int32_t friendnumber, uint8_t packet_id, const uint8_t *data,
                                uint32_t length, uint8_t congestion_control);

// friend_not_valid determines if the friendnumber passed is valid in the Messenger object
static uint8_t friend_not_valid(const Messenger *m, int32_t friendnumber)
{
    if ((unsigned int)friendnumber < m->numfriends) {
        if (m->friendlist[friendnumber].status != 0) {
            return 0;
        }
    }

    return 1;
}

/* Set the size of the friend list to numfriends.
 *
 *  return -1 if realloc fails.
 */
static int realloc_friendlist(Messenger *m, uint32_t num)
{
    if (num == 0) {
        free(m->friendlist);
        m->friendlist = nullptr;
        return 0;
    }

    Friend *newfriendlist = (Friend *)realloc(m->friendlist, num * sizeof(Friend));

    if (newfriendlist == nullptr) {
        return -1;
    }

    m->friendlist = newfriendlist;
    return 0;
}

/*  return the friend id associated to that public key.
 *  return -1 if no such friend.
 */
int32_t getfriend_id(const Messenger *m, const uint8_t *real_pk)
{
    uint32_t i;

    for (i = 0; i < m->numfriends; ++i) {
        if (m->friendlist[i].status > 0) {
            if (id_equal(real_pk, m->friendlist[i].real_pk)) {
                return i;
            }
        }
    }

    return -1;
}

/* Copies the public key associated to that friend id into real_pk buffer.
 * Make sure that real_pk is of size CRYPTO_PUBLIC_KEY_SIZE.
 *
 *  return 0 if success.
 *  return -1 if failure.
 */
int get_real_pk(const Messenger *m, int32_t friendnumber, uint8_t *real_pk)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    memcpy(real_pk, m->friendlist[friendnumber].real_pk, CRYPTO_PUBLIC_KEY_SIZE);
    return 0;
}

/*  return friend connection id on success.
 *  return -1 if failure.
 */
int getfriendcon_id(const Messenger *m, int32_t friendnumber)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    return m->friendlist[friendnumber].friendcon_id;
}

/*
 *  return a uint16_t that represents the checksum of address of length len.
 */
static uint16_t address_checksum(const uint8_t *address, uint32_t len)
{
    uint8_t checksum[2] = {0};
    uint16_t check;
    uint32_t i;

    for (i = 0; i < len; ++i) {
        checksum[i % 2] ^= address[i];
    }

    memcpy(&check, checksum, sizeof(check));
    return check;
}

/* Format: [real_pk (32 bytes)][nospam number (4 bytes)][checksum (2 bytes)]
 *
 *  return FRIEND_ADDRESS_SIZE byte address to give to others.
 */
void getaddress(const Messenger *m, uint8_t *address)
{
    id_copy(address, nc_get_self_public_key(m->net_crypto));
    uint32_t nospam = get_nospam(m->fr);
    memcpy(address + CRYPTO_PUBLIC_KEY_SIZE, &nospam, sizeof(nospam));
    uint16_t checksum = address_checksum(address, FRIEND_ADDRESS_SIZE - sizeof(checksum));
    memcpy(address + CRYPTO_PUBLIC_KEY_SIZE + sizeof(nospam), &checksum, sizeof(checksum));
}

static int send_online_packet(Messenger *m, int32_t friendnumber)
{
    if (friend_not_valid(m, friendnumber)) {
        return 0;
    }

    uint8_t packet = PACKET_ID_ONLINE;
    return write_cryptpacket(m->net_crypto, friend_connection_crypt_connection_id(m->fr_c,
                             m->friendlist[friendnumber].friendcon_id), &packet, sizeof(packet), 0) != -1;
}

static int send_offline_packet(Messenger *m, int friendcon_id)
{
    uint8_t packet = PACKET_ID_OFFLINE;
    return write_cryptpacket(m->net_crypto, friend_connection_crypt_connection_id(m->fr_c, friendcon_id), &packet,
                             sizeof(packet), 0) != -1;
}

static int m_handle_status(void *object, int i, uint8_t status, void *userdata);
static int m_handle_packet(void *object, int i, const uint8_t *temp, uint16_t len, void *userdata);
static int m_handle_custom_lossy_packet(void *object, int friend_num, const uint8_t *packet, uint16_t length,
                                        void *userdata);

static int32_t init_new_friend(Messenger *m, const uint8_t *real_pk, uint8_t status)
{
    /* Resize the friend list if necessary. */
    if (realloc_friendlist(m, m->numfriends + 1) != 0) {
        return FAERR_NOMEM;
    }

    memset(&m->friendlist[m->numfriends], 0, sizeof(Friend));

    int friendcon_id = new_friend_connection(m->fr_c, real_pk);

    if (friendcon_id == -1) {
        return FAERR_NOMEM;
    }

    uint32_t i;

    for (i = 0; i <= m->numfriends; ++i) {
        if (m->friendlist[i].status == NOFRIEND) {
            m->friendlist[i].status = status;
            m->friendlist[i].friendcon_id = friendcon_id;
            m->friendlist[i].friendrequest_lastsent = 0;
            id_copy(m->friendlist[i].real_pk, real_pk);
            m->friendlist[i].statusmessage_length = 0;
            m->friendlist[i].userstatus = USERSTATUS_NONE;
            m->friendlist[i].is_typing = 0;
            m->friendlist[i].message_id = 0;
            friend_connection_callbacks(m->fr_c, friendcon_id, MESSENGER_CALLBACK_INDEX, &m_handle_status, &m_handle_packet,
                                        &m_handle_custom_lossy_packet, m, i);

            if (m->numfriends == i) {
                ++m->numfriends;
            }

            if (friend_con_connected(m->fr_c, friendcon_id) == FRIENDCONN_STATUS_CONNECTED) {
                send_online_packet(m, i);
            }

            return i;
        }
    }

    return FAERR_NOMEM;
}

/*
 * Add a friend.
 * Set the data that will be sent along with friend request.
 * Address is the address of the friend (returned by getaddress of the friend you wish to add) it must be FRIEND_ADDRESS_SIZE bytes.
 * data is the data and length is the length.
 *
 *  return the friend number if success.
 *  return FA_TOOLONG if message length is too long.
 *  return FAERR_NOMESSAGE if no message (message length must be >= 1 byte).
 *  return FAERR_OWNKEY if user's own key.
 *  return FAERR_ALREADYSENT if friend request already sent or already a friend.
 *  return FAERR_BADCHECKSUM if bad checksum in address.
 *  return FAERR_SETNEWNOSPAM if the friend was already there but the nospam was different.
 *  (the nospam for that friend was set to the new one).
 *  return FAERR_NOMEM if increasing the friend list size fails.
 */
int32_t m_addfriend(Messenger *m, const uint8_t *address, const uint8_t *data, uint16_t length)
{
    if (length > MAX_FRIEND_REQUEST_DATA_SIZE) {
        return FAERR_TOOLONG;
    }

    uint8_t real_pk[CRYPTO_PUBLIC_KEY_SIZE];
    id_copy(real_pk, address);

    if (!public_key_valid(real_pk)) {
        return FAERR_BADCHECKSUM;
    }

    uint16_t check, checksum = address_checksum(address, FRIEND_ADDRESS_SIZE - sizeof(checksum));
    memcpy(&check, address + CRYPTO_PUBLIC_KEY_SIZE + sizeof(uint32_t), sizeof(check));

    if (check != checksum) {
        return FAERR_BADCHECKSUM;
    }

    if (length < 1) {
        return FAERR_NOMESSAGE;
    }

    if (id_equal(real_pk, nc_get_self_public_key(m->net_crypto))) {
        return FAERR_OWNKEY;
    }

    int32_t friend_id = getfriend_id(m, real_pk);

    if (friend_id != -1) {
        if (m->friendlist[friend_id].status >= FRIEND_CONFIRMED) {
            return FAERR_ALREADYSENT;
        }

        uint32_t nospam;
        memcpy(&nospam, address + CRYPTO_PUBLIC_KEY_SIZE, sizeof(nospam));

        if (m->friendlist[friend_id].friendrequest_nospam == nospam) {
            return FAERR_ALREADYSENT;
        }

        m->friendlist[friend_id].friendrequest_nospam = nospam;
        return FAERR_SETNEWNOSPAM;
    }

    int32_t ret = init_new_friend(m, real_pk, FRIEND_ADDED);

    if (ret < 0) {
        return ret;
    }

    m->friendlist[ret].friendrequest_timeout = FRIENDREQUEST_TIMEOUT;
    memcpy(m->friendlist[ret].info, data, length);
    m->friendlist[ret].info_size = length;
    memcpy(&m->friendlist[ret].friendrequest_nospam, address + CRYPTO_PUBLIC_KEY_SIZE, sizeof(uint32_t));

    return ret;
}

int32_t m_addfriend_norequest(Messenger *m, const uint8_t *real_pk)
{
    if (getfriend_id(m, real_pk) != -1) {
        return FAERR_ALREADYSENT;
    }

    if (!public_key_valid(real_pk)) {
        return FAERR_BADCHECKSUM;
    }

    if (id_equal(real_pk, nc_get_self_public_key(m->net_crypto))) {
        return FAERR_OWNKEY;
    }

    return init_new_friend(m, real_pk, FRIEND_CONFIRMED);
}

static int clear_receipts(Messenger *m, int32_t friendnumber)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    struct Receipts *receipts = m->friendlist[friendnumber].receipts_start;

    while (receipts) {
        struct Receipts *temp_r = receipts->next;
        free(receipts);
        receipts = temp_r;
    }

    m->friendlist[friendnumber].receipts_start = nullptr;
    m->friendlist[friendnumber].receipts_end = nullptr;
    return 0;
}

static int add_receipt(Messenger *m, int32_t friendnumber, uint32_t packet_num, uint32_t msg_id)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    struct Receipts *new_receipts = (struct Receipts *)calloc(1, sizeof(struct Receipts));

    if (!new_receipts) {
        return -1;
    }

    new_receipts->packet_num = packet_num;
    new_receipts->msg_id = msg_id;

    if (!m->friendlist[friendnumber].receipts_start) {
        m->friendlist[friendnumber].receipts_start = new_receipts;
    } else {
        m->friendlist[friendnumber].receipts_end->next = new_receipts;
    }

    m->friendlist[friendnumber].receipts_end = new_receipts;
    new_receipts->next = nullptr;
    return 0;
}
/*
 * return -1 on failure.
 * return 0 if packet was received.
 */
static int friend_received_packet(const Messenger *m, int32_t friendnumber, uint32_t number)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    return cryptpacket_received(m->net_crypto, friend_connection_crypt_connection_id(m->fr_c,
                                m->friendlist[friendnumber].friendcon_id), number);
}

static int do_receipts(Messenger *m, int32_t friendnumber, void *userdata)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    struct Receipts *receipts = m->friendlist[friendnumber].receipts_start;

    while (receipts) {
        if (friend_received_packet(m, friendnumber, receipts->packet_num) == -1) {
            break;
        }

        if (m->read_receipt) {
            (*m->read_receipt)(m, friendnumber, receipts->msg_id, userdata);
        }

        struct Receipts *r_next = receipts->next;

        free(receipts);

        m->friendlist[friendnumber].receipts_start = r_next;

        receipts = r_next;
    }

    if (!m->friendlist[friendnumber].receipts_start) {
        m->friendlist[friendnumber].receipts_end = nullptr;
    }

    return 0;
}

/* Remove a friend.
 *
 *  return 0 if success.
 *  return -1 if failure.
 */
int m_delfriend(Messenger *m, int32_t friendnumber)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    if (m->friend_connectionstatuschange_internal) {
        m->friend_connectionstatuschange_internal(m, friendnumber, 0, m->friend_connectionstatuschange_internal_userdata);
    }

    clear_receipts(m, friendnumber);
    remove_request_received(m->fr, m->friendlist[friendnumber].real_pk);
    friend_connection_callbacks(m->fr_c, m->friendlist[friendnumber].friendcon_id, MESSENGER_CALLBACK_INDEX, nullptr,
                                nullptr, nullptr, nullptr, 0);

    if (friend_con_connected(m->fr_c, m->friendlist[friendnumber].friendcon_id) == FRIENDCONN_STATUS_CONNECTED) {
        send_offline_packet(m, m->friendlist[friendnumber].friendcon_id);
    }

    kill_friend_connection(m->fr_c, m->friendlist[friendnumber].friendcon_id);
    memset(&m->friendlist[friendnumber], 0, sizeof(Friend));
    uint32_t i;

    for (i = m->numfriends; i != 0; --i) {
        if (m->friendlist[i - 1].status != NOFRIEND) {
            break;
        }
    }

    m->numfriends = i;

    if (realloc_friendlist(m, m->numfriends) != 0) {
        return FAERR_NOMEM;
    }

    return 0;
}

int m_get_friend_connectionstatus(const Messenger *m, int32_t friendnumber)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    if (m->friendlist[friendnumber].status == FRIEND_ONLINE) {
        bool direct_connected = 0;
        unsigned int num_online_relays = 0;
        int crypt_conn_id = friend_connection_crypt_connection_id(m->fr_c, m->friendlist[friendnumber].friendcon_id);
        crypto_connection_status(m->net_crypto, crypt_conn_id, &direct_connected, &num_online_relays);

        if (direct_connected) {
            return CONNECTION_UDP;
        }

        if (num_online_relays) {
            return CONNECTION_TCP;
        }

        return CONNECTION_UNKNOWN;
    }

    return CONNECTION_NONE;
}

int m_friend_exists(const Messenger *m, int32_t friendnumber)
{
    if (friend_not_valid(m, friendnumber)) {
        return 0;
    }

    return 1;
}

/* Send a message of type.
 *
 * return -1 if friend not valid.
 * return -2 if too large.
 * return -3 if friend not online.
 * return -4 if send failed (because queue is full).
 * return -5 if bad type.
 * return 0 if success.
 */
int m_send_message_generic(Messenger *m, int32_t friendnumber, uint8_t type, const uint8_t *message, uint32_t length,
                           uint32_t *message_id)
{
    if (type > MESSAGE_ACTION) {
        return -5;
    }

    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    if (length >= MAX_CRYPTO_DATA_SIZE) {
        return -2;
    }

    if (m->friendlist[friendnumber].status != FRIEND_ONLINE) {
        return -3;
    }

    VLA(uint8_t, packet, length + 1);
    packet[0] = type + PACKET_ID_MESSAGE;

    if (length != 0) {
        memcpy(packet + 1, message, length);
    }

    int64_t packet_num = write_cryptpacket(m->net_crypto, friend_connection_crypt_connection_id(m->fr_c,
                                           m->friendlist[friendnumber].friendcon_id), packet, length + 1, 0);

    if (packet_num == -1) {
        return -4;
    }

    uint32_t msg_id = ++m->friendlist[friendnumber].message_id;

    add_receipt(m, friendnumber, packet_num, msg_id);

    if (message_id) {
        *message_id = msg_id;
    }

    return 0;
}

/* Send a name packet to friendnumber.
 * length is the length with the NULL terminator.
 */
static int m_sendname(const Messenger *m, int32_t friendnumber, const uint8_t *name, uint16_t length)
{
    if (length > MAX_NAME_LENGTH) {
        return 0;
    }

    return write_cryptpacket_id(m, friendnumber, PACKET_ID_NICKNAME, name, length, 0);
}

/* Set the name and name_length of a friend.
 *
 *  return 0 if success.
 *  return -1 if failure.
 */
int setfriendname(Messenger *m, int32_t friendnumber, const uint8_t *name, uint16_t length)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    if (length > MAX_NAME_LENGTH || length == 0) {
        return -1;
    }

    m->friendlist[friendnumber].name_length = length;
    memcpy(m->friendlist[friendnumber].name, name, length);
    return 0;
}

/* Set our nickname
 * name must be a string of maximum MAX_NAME_LENGTH length.
 * length must be at least 1 byte.
 * length is the length of name with the NULL terminator.
 *
 *  return 0 if success.
 *  return -1 if failure.
 */
int setname(Messenger *m, const uint8_t *name, uint16_t length)
{
    if (length > MAX_NAME_LENGTH) {
        return -1;
    }

    if (m->name_length == length && (length == 0 || memcmp(name, m->name, length) == 0)) {
        return 0;
    }

    if (length) {
        memcpy(m->name, name, length);
    }

    m->name_length = length;
    uint32_t i;

    for (i = 0; i < m->numfriends; ++i) {
        m->friendlist[i].name_sent = 0;
    }

    return 0;
}

/* Get our nickname and put it in name.
 * name needs to be a valid memory location with a size of at least MAX_NAME_LENGTH bytes.
 *
 *  return the length of the name.
 */
uint16_t getself_name(const Messenger *m, uint8_t *name)
{
    if (name == nullptr) {
        return 0;
    }

    memcpy(name, m->name, m->name_length);

    return m->name_length;
}

/* Get name of friendnumber and put it in name.
 * name needs to be a valid memory location with a size of at least MAX_NAME_LENGTH bytes.
 *
 *  return length of name if success.
 *  return -1 if failure.
 */
int getname(const Messenger *m, int32_t friendnumber, uint8_t *name)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    memcpy(name, m->friendlist[friendnumber].name, m->friendlist[friendnumber].name_length);
    return m->friendlist[friendnumber].name_length;
}

int m_get_name_size(const Messenger *m, int32_t friendnumber)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    return m->friendlist[friendnumber].name_length;
}

int m_get_self_name_size(const Messenger *m)
{
    return m->name_length;
}

int m_set_statusmessage(Messenger *m, const uint8_t *status, uint16_t length)
{
    if (length > MAX_STATUSMESSAGE_LENGTH) {
        return -1;
    }

    if (m->statusmessage_length == length && (length == 0 || memcmp(m->statusmessage, status, length) == 0)) {
        return 0;
    }

    if (length) {
        memcpy(m->statusmessage, status, length);
    }

    m->statusmessage_length = length;

    uint32_t i;

    for (i = 0; i < m->numfriends; ++i) {
        m->friendlist[i].statusmessage_sent = 0;
    }

    return 0;
}

int m_set_userstatus(Messenger *m, uint8_t status)
{
    if (status >= USERSTATUS_INVALID) {
        return -1;
    }

    if (m->userstatus == status) {
        return 0;
    }

    m->userstatus = (USERSTATUS)status;
    uint32_t i;

    for (i = 0; i < m->numfriends; ++i) {
        m->friendlist[i].userstatus_sent = 0;
    }

    return 0;
}

/* return the size of friendnumber's user status.
 * Guaranteed to be at most MAX_STATUSMESSAGE_LENGTH.
 */
int m_get_statusmessage_size(const Messenger *m, int32_t friendnumber)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    return m->friendlist[friendnumber].statusmessage_length;
}

/*  Copy the user status of friendnumber into buf, truncating if needed to maxlen
 *  bytes, use m_get_statusmessage_size to find out how much you need to allocate.
 */
int m_copy_statusmessage(const Messenger *m, int32_t friendnumber, uint8_t *buf, uint32_t maxlen)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    int msglen = MIN(maxlen, m->friendlist[friendnumber].statusmessage_length);

    memcpy(buf, m->friendlist[friendnumber].statusmessage, msglen);
    memset(buf + msglen, 0, maxlen - msglen);
    return msglen;
}

/* return the size of friendnumber's user status.
 * Guaranteed to be at most MAX_STATUSMESSAGE_LENGTH.
 */
int m_get_self_statusmessage_size(const Messenger *m)
{
    return m->statusmessage_length;
}

int m_copy_self_statusmessage(const Messenger *m, uint8_t *buf)
{
    memcpy(buf, m->statusmessage, m->statusmessage_length);
    return m->statusmessage_length;
}

uint8_t m_get_userstatus(const Messenger *m, int32_t friendnumber)
{
    if (friend_not_valid(m, friendnumber)) {
        return USERSTATUS_INVALID;
    }

    uint8_t status = m->friendlist[friendnumber].userstatus;

    if (status >= USERSTATUS_INVALID) {
        status = USERSTATUS_NONE;
    }

    return status;
}

uint8_t m_get_self_userstatus(const Messenger *m)
{
    return m->userstatus;
}

uint64_t m_get_last_online(const Messenger *m, int32_t friendnumber)
{
    if (friend_not_valid(m, friendnumber)) {
        return UINT64_MAX;
    }

    return m->friendlist[friendnumber].last_seen_time;
}

int m_set_usertyping(Messenger *m, int32_t friendnumber, uint8_t is_typing)
{
    if (is_typing != 0 && is_typing != 1) {
        return -1;
    }

    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    if (m->friendlist[friendnumber].user_istyping == is_typing) {
        return 0;
    }

    m->friendlist[friendnumber].user_istyping = is_typing;
    m->friendlist[friendnumber].user_istyping_sent = 0;

    return 0;
}

int m_get_istyping(const Messenger *m, int32_t friendnumber)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    return m->friendlist[friendnumber].is_typing;
}

static int send_statusmessage(const Messenger *m, int32_t friendnumber, const uint8_t *status, uint16_t length)
{
    return write_cryptpacket_id(m, friendnumber, PACKET_ID_STATUSMESSAGE, status, length, 0);
}

static int send_userstatus(const Messenger *m, int32_t friendnumber, uint8_t status)
{
    return write_cryptpacket_id(m, friendnumber, PACKET_ID_USERSTATUS, &status, sizeof(status), 0);
}

static int send_user_istyping(const Messenger *m, int32_t friendnumber, uint8_t is_typing)
{
    uint8_t typing = is_typing;
    return write_cryptpacket_id(m, friendnumber, PACKET_ID_TYPING, &typing, sizeof(typing), 0);
}

static int set_friend_statusmessage(const Messenger *m, int32_t friendnumber, const uint8_t *status, uint16_t length)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    if (length > MAX_STATUSMESSAGE_LENGTH) {
        return -1;
    }

    if (length) {
        memcpy(m->friendlist[friendnumber].statusmessage, status, length);
    }

    m->friendlist[friendnumber].statusmessage_length = length;
    return 0;
}

static void set_friend_userstatus(const Messenger *m, int32_t friendnumber, uint8_t status)
{
    m->friendlist[friendnumber].userstatus = (USERSTATUS)status;
}

static void set_friend_typing(const Messenger *m, int32_t friendnumber, uint8_t is_typing)
{
    m->friendlist[friendnumber].is_typing = is_typing;
}

void m_callback_log(Messenger *m, logger_cb *function, void *context, void *userdata)
{
    logger_callback_log(m->log, function, context, userdata);
}

/* Set the function that will be executed when a friend request is received. */
void m_callback_friendrequest(Messenger *m, void (*function)(Messenger *m, const uint8_t *, const uint8_t *, size_t,
                              void *))
{
    callback_friendrequest(m->fr, (void (*)(void *, const uint8_t *, const uint8_t *, size_t, void *))function, m);
}

/* Set the function that will be executed when a message from a friend is received. */
void m_callback_friendmessage(Messenger *m, void (*function)(Messenger *m, uint32_t, unsigned int, const uint8_t *,
                              size_t, void *))
{
    m->friend_message = function;
}

void m_callback_namechange(Messenger *m, void (*function)(Messenger *m, uint32_t, const uint8_t *, size_t, void *))
{
    m->friend_namechange = function;
}

void m_callback_statusmessage(Messenger *m, void (*function)(Messenger *m, uint32_t, const uint8_t *, size_t, void *))
{
    m->friend_statusmessagechange = function;
}

void m_callback_userstatus(Messenger *m, void (*function)(Messenger *m, uint32_t, unsigned int, void *))
{
    m->friend_userstatuschange = function;
}

void m_callback_typingchange(Messenger *m, void(*function)(Messenger *m, uint32_t, bool, void *))
{
    m->friend_typingchange = function;
}

void m_callback_read_receipt(Messenger *m, void (*function)(Messenger *m, uint32_t, uint32_t, void *))
{
    m->read_receipt = function;
}

void m_callback_connectionstatus(Messenger *m, void (*function)(Messenger *m, uint32_t, unsigned int, void *))
{
    m->friend_connectionstatuschange = function;
}

void m_callback_core_connection(Messenger *m, void (*function)(Messenger *m, unsigned int, void *))
{
    m->core_connection_change = function;
}

void m_callback_connectionstatus_internal_av(Messenger *m, void (*function)(Messenger *m, uint32_t, uint8_t, void *),
        void *userdata)
{
    m->friend_connectionstatuschange_internal = function;
    m->friend_connectionstatuschange_internal_userdata = userdata;
}

static void check_friend_tcp_udp(Messenger *m, int32_t friendnumber, void *userdata)
{
    int last_connection_udp_tcp = m->friendlist[friendnumber].last_connection_udp_tcp;

    int ret = m_get_friend_connectionstatus(m, friendnumber);

    if (ret == -1) {
        return;
    }

    if (ret == CONNECTION_UNKNOWN) {
        if (last_connection_udp_tcp == CONNECTION_UDP) {
            return;
        }

        ret = CONNECTION_TCP;
    }

    if (last_connection_udp_tcp != ret) {
        if (m->friend_connectionstatuschange) {
            m->friend_connectionstatuschange(m, friendnumber, ret, userdata);
        }
    }

    m->friendlist[friendnumber].last_connection_udp_tcp = ret;
}

static void break_files(const Messenger *m, int32_t friendnumber);
static void check_friend_connectionstatus(Messenger *m, int32_t friendnumber, uint8_t status, void *userdata)
{
    if (status == NOFRIEND) {
        return;
    }

    const uint8_t was_online = m->friendlist[friendnumber].status == FRIEND_ONLINE;
    const uint8_t is_online = status == FRIEND_ONLINE;

    if (is_online != was_online) {
        if (was_online) {
            break_files(m, friendnumber);
            clear_receipts(m, friendnumber);
        } else {
            m->friendlist[friendnumber].name_sent = 0;
            m->friendlist[friendnumber].userstatus_sent = 0;
            m->friendlist[friendnumber].statusmessage_sent = 0;
            m->friendlist[friendnumber].user_istyping_sent = 0;
        }

        m->friendlist[friendnumber].status = status;

        check_friend_tcp_udp(m, friendnumber, userdata);

        if (m->friend_connectionstatuschange_internal) {
            m->friend_connectionstatuschange_internal(m, friendnumber, is_online,
                    m->friend_connectionstatuschange_internal_userdata);
        }
    }
}

static void set_friend_status(Messenger *m, int32_t friendnumber, uint8_t status, void *userdata)
{
    check_friend_connectionstatus(m, friendnumber, status, userdata);
    m->friendlist[friendnumber].status = status;
}

static int write_cryptpacket_id(const Messenger *m, int32_t friendnumber, uint8_t packet_id, const uint8_t *data,
                                uint32_t length, uint8_t congestion_control)
{
    if (friend_not_valid(m, friendnumber)) {
        return 0;
    }

    if (length >= MAX_CRYPTO_DATA_SIZE || m->friendlist[friendnumber].status != FRIEND_ONLINE) {
        return 0;
    }

    VLA(uint8_t, packet, length + 1);
    packet[0] = packet_id;

    if (length != 0) {
        memcpy(packet + 1, data, length);
    }

    return write_cryptpacket(m->net_crypto, friend_connection_crypt_connection_id(m->fr_c,
                             m->friendlist[friendnumber].friendcon_id), packet, length + 1, congestion_control) != -1;
}

/**********CONFERENCES************/


/* Set the callback for conference invites.
 *
 *  Function(Messenger *m, uint32_t friendnumber, uint8_t *data, uint16_t length, void *userdata)
 */
void m_callback_conference_invite(Messenger *m, void (*function)(Messenger *m, uint32_t, const uint8_t *, uint16_t,
                                  void *))
{
    m->conference_invite = function;
}


/* Send a conference invite packet.
 *
 *  return 1 on success
 *  return 0 on failure
 */
int send_conference_invite_packet(const Messenger *m, int32_t friendnumber, const uint8_t *data, uint16_t length)
{
    return write_cryptpacket_id(m, friendnumber, PACKET_ID_INVITE_CONFERENCE, data, length, 0);
}

/****************FILE SENDING*****************/


/* Set the callback for file send requests.
 *
 *  Function(Tox *tox, uint32_t friendnumber, uint32_t filenumber, uint32_t filetype, uint64_t filesize, uint8_t *filename, size_t filename_length, void *userdata)
 */
void callback_file_sendrequest(Messenger *m, void (*function)(Messenger *m,  uint32_t, uint32_t, uint32_t, uint64_t,
                               const uint8_t *, size_t, void *))
{
    m->file_sendrequest = function;
}

/* Set the callback for file control requests.
 *
 *  Function(Tox *tox, uint32_t friendnumber, uint32_t filenumber, unsigned int control_type, void *userdata)
 *
 */
void callback_file_control(Messenger *m, void (*function)(Messenger *m, uint32_t, uint32_t, unsigned int, void *))
{
    m->file_filecontrol = function;
}

/* Set the callback for file data.
 *
 *  Function(Tox *tox, uint32_t friendnumber, uint32_t filenumber, uint64_t position, uint8_t *data, size_t length, void *userdata)
 *
 */
void callback_file_data(Messenger *m, void (*function)(Messenger *m, uint32_t, uint32_t, uint64_t, const uint8_t *,
                        size_t, void *))
{
    m->file_filedata = function;
}

/* Set the callback for file request chunk.
 *
 *  Function(Tox *tox, uint32_t friendnumber, uint32_t filenumber, uint64_t position, size_t length, void *userdata)
 *
 */
void callback_file_reqchunk(Messenger *m, void (*function)(Messenger *m, uint32_t, uint32_t, uint64_t, size_t, void *))
{
    m->file_reqchunk = function;
}

#define MAX_FILENAME_LENGTH 255

/* Copy the file transfer file id to file_id
 *
 * return 0 on success.
 * return -1 if friend not valid.
 * return -2 if filenumber not valid
 */
int file_get_id(const Messenger *m, int32_t friendnumber, uint32_t filenumber, uint8_t *file_id)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    if (m->friendlist[friendnumber].status != FRIEND_ONLINE) {
        return -2;
    }

    uint32_t temp_filenum;
    uint8_t send_receive, file_number;

    if (filenumber >= (1 << 16)) {
        send_receive = 1;
        temp_filenum = (filenumber >> 16) - 1;
    } else {
        send_receive = 0;
        temp_filenum = filenumber;
    }

    if (temp_filenum >= MAX_CONCURRENT_FILE_PIPES) {
        return -2;
    }

    file_number = temp_filenum;

    struct File_Transfers *ft;

    if (send_receive) {
        ft = &m->friendlist[friendnumber].file_receiving[file_number];
    } else {
        ft = &m->friendlist[friendnumber].file_sending[file_number];
    }

    if (ft->status == FILESTATUS_NONE) {
        return -2;
    }

    memcpy(file_id, ft->id, FILE_ID_LENGTH);
    return 0;
}

/* Send a file send request.
 * Maximum filename length is 255 bytes.
 *  return 1 on success
 *  return 0 on failure
 */
static int file_sendrequest(const Messenger *m, int32_t friendnumber, uint8_t filenumber, uint32_t file_type,
                            uint64_t filesize, const uint8_t *file_id, const uint8_t *filename, uint16_t filename_length)
{
    if (friend_not_valid(m, friendnumber)) {
        return 0;
    }

    if (filename_length > MAX_FILENAME_LENGTH) {
        return 0;
    }

    VLA(uint8_t, packet, 1 + sizeof(file_type) + sizeof(filesize) + FILE_ID_LENGTH + filename_length);
    packet[0] = filenumber;
    file_type = net_htonl(file_type);
    memcpy(packet + 1, &file_type, sizeof(file_type));
    host_to_net((uint8_t *)&filesize, sizeof(filesize));
    memcpy(packet + 1 + sizeof(file_type), &filesize, sizeof(filesize));
    memcpy(packet + 1 + sizeof(file_type) + sizeof(filesize), file_id, FILE_ID_LENGTH);

    if (filename_length) {
        memcpy(packet + 1 + sizeof(file_type) + sizeof(filesize) + FILE_ID_LENGTH, filename, filename_length);
    }

    return write_cryptpacket_id(m, friendnumber, PACKET_ID_FILE_SENDREQUEST, packet, SIZEOF_VLA(packet), 0);
}

/* Send a file send request.
 * Maximum filename length is 255 bytes.
 *  return file number on success
 *  return -1 if friend not found.
 *  return -2 if filename length invalid.
 *  return -3 if no more file sending slots left.
 *  return -4 if could not send packet (friend offline).
 *
 */
long int new_filesender(const Messenger *m, int32_t friendnumber, uint32_t file_type, uint64_t filesize,
                        const uint8_t *file_id, const uint8_t *filename, uint16_t filename_length)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    if (filename_length > MAX_FILENAME_LENGTH) {
        return -2;
    }

    uint32_t i;

    for (i = 0; i < MAX_CONCURRENT_FILE_PIPES; ++i) {
        if (m->friendlist[friendnumber].file_sending[i].status == FILESTATUS_NONE) {
            break;
        }
    }

    if (i == MAX_CONCURRENT_FILE_PIPES) {
        return -3;
    }

    if (file_sendrequest(m, friendnumber, i, file_type, filesize, file_id, filename, filename_length) == 0) {
        return -4;
    }

    struct File_Transfers *ft = &m->friendlist[friendnumber].file_sending[i];

    ft->status = FILESTATUS_NOT_ACCEPTED;

    ft->size = filesize;

    ft->transferred = 0;

    ft->requested = 0;

    ft->slots_allocated = 0;

    ft->paused = FILE_PAUSE_NOT;

    memcpy(ft->id, file_id, FILE_ID_LENGTH);

    ++m->friendlist[friendnumber].num_sending_files;

    return i;
}

static int send_file_control_packet(const Messenger *m, int32_t friendnumber, uint8_t send_receive, uint8_t filenumber,
                                    uint8_t control_type, uint8_t *data, uint16_t data_length)
{
    if ((unsigned int)(1 + 3 + data_length) > MAX_CRYPTO_DATA_SIZE) {
        return -1;
    }

    VLA(uint8_t, packet, 3 + data_length);

    packet[0] = send_receive;
    packet[1] = filenumber;
    packet[2] = control_type;

    if (data_length) {
        memcpy(packet + 3, data, data_length);
    }

    return write_cryptpacket_id(m, friendnumber, PACKET_ID_FILE_CONTROL, packet, SIZEOF_VLA(packet), 0);
}

/* Send a file control request.
 *
 *  return 0 on success
 *  return -1 if friend not valid.
 *  return -2 if friend not online.
 *  return -3 if file number invalid.
 *  return -4 if file control is bad.
 *  return -5 if file already paused.
 *  return -6 if resume file failed because it was only paused by the other.
 *  return -7 if resume file failed because it wasn't paused.
 *  return -8 if packet failed to send.
 */
int file_control(const Messenger *m, int32_t friendnumber, uint32_t filenumber, unsigned int control)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    if (m->friendlist[friendnumber].status != FRIEND_ONLINE) {
        return -2;
    }

    uint32_t temp_filenum;
    uint8_t send_receive, file_number;

    if (filenumber >= (1 << 16)) {
        send_receive = 1;
        temp_filenum = (filenumber >> 16) - 1;
    } else {
        send_receive = 0;
        temp_filenum = filenumber;
    }

    if (temp_filenum >= MAX_CONCURRENT_FILE_PIPES) {
        return -3;
    }

    file_number = temp_filenum;

    struct File_Transfers *ft;

    if (send_receive) {
        ft = &m->friendlist[friendnumber].file_receiving[file_number];
    } else {
        ft = &m->friendlist[friendnumber].file_sending[file_number];
    }

    if (ft->status == FILESTATUS_NONE) {
        return -3;
    }

    if (control > FILECONTROL_KILL) {
        return -4;
    }

    if (control == FILECONTROL_PAUSE && ((ft->paused & FILE_PAUSE_US) || ft->status != FILESTATUS_TRANSFERRING)) {
        return -5;
    }

    if (control == FILECONTROL_ACCEPT) {
        if (ft->status == FILESTATUS_TRANSFERRING) {
            if (!(ft->paused & FILE_PAUSE_US)) {
                if (ft->paused & FILE_PAUSE_OTHER) {
                    return -6;
                }

                return -7;
            }
        } else {
            if (ft->status != FILESTATUS_NOT_ACCEPTED) {
                return -7;
            }

            if (!send_receive) {
                return -6;
            }
        }
    }

    if (send_file_control_packet(m, friendnumber, send_receive, file_number, control, nullptr, 0)) {
        if (control == FILECONTROL_KILL) {
            ft->status = FILESTATUS_NONE;

            if (send_receive == 0) {
                --m->friendlist[friendnumber].num_sending_files;
            }
        } else if (control == FILECONTROL_PAUSE) {
            ft->paused |= FILE_PAUSE_US;
        } else if (control == FILECONTROL_ACCEPT) {
            ft->status = FILESTATUS_TRANSFERRING;

            if (ft->paused & FILE_PAUSE_US) {
                ft->paused ^=  FILE_PAUSE_US;
            }
        }
    } else {
        return -8;
    }

    return 0;
}

/* Send a seek file control request.
 *
 *  return 0 on success
 *  return -1 if friend not valid.
 *  return -2 if friend not online.
 *  return -3 if file number invalid.
 *  return -4 if not receiving file.
 *  return -5 if file status wrong.
 *  return -6 if position bad.
 *  return -8 if packet failed to send.
 */
int file_seek(const Messenger *m, int32_t friendnumber, uint32_t filenumber, uint64_t position)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    if (m->friendlist[friendnumber].status != FRIEND_ONLINE) {
        return -2;
    }

    if (filenumber < (1 << 16)) {
        // Not receiving.
        return -4;
    }

    uint32_t temp_filenum = (filenumber >> 16) - 1;

    if (temp_filenum >= MAX_CONCURRENT_FILE_PIPES) {
        return -3;
    }

    assert(temp_filenum <= UINT8_MAX);
    uint8_t file_number = temp_filenum;

    // We're always receiving at this point.
    struct File_Transfers *ft = &m->friendlist[friendnumber].file_receiving[file_number];

    if (ft->status == FILESTATUS_NONE) {
        return -3;
    }

    if (ft->status != FILESTATUS_NOT_ACCEPTED) {
        return -5;
    }

    if (position >= ft->size) {
        return -6;
    }

    uint64_t sending_pos = position;
    host_to_net((uint8_t *)&sending_pos, sizeof(sending_pos));

    if (send_file_control_packet(m, friendnumber, 1, file_number, FILECONTROL_SEEK, (uint8_t *)&sending_pos,
                                 sizeof(sending_pos))) {
        ft->transferred = position;
    } else {
        return -8;
    }

    return 0;
}

/* return packet number on success.
 * return -1 on failure.
 */
static int64_t send_file_data_packet(const Messenger *m, int32_t friendnumber, uint8_t filenumber, const uint8_t *data,
                                     uint16_t length)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    VLA(uint8_t, packet, 2 + length);
    packet[0] = PACKET_ID_FILE_DATA;
    packet[1] = filenumber;

    if (length) {
        memcpy(packet + 2, data, length);
    }

    return write_cryptpacket(m->net_crypto, friend_connection_crypt_connection_id(m->fr_c,
                             m->friendlist[friendnumber].friendcon_id), packet, SIZEOF_VLA(packet), 1);
}

#define MAX_FILE_DATA_SIZE (MAX_CRYPTO_DATA_SIZE - 2)
#define MIN_SLOTS_FREE (CRYPTO_MIN_QUEUE_LENGTH / 4)
/* Send file data.
 *
 *  return 0 on success
 *  return -1 if friend not valid.
 *  return -2 if friend not online.
 *  return -3 if filenumber invalid.
 *  return -4 if file transfer not transferring.
 *  return -5 if bad data size.
 *  return -6 if packet queue full.
 *  return -7 if wrong position.
 */
int file_data(const Messenger *m, int32_t friendnumber, uint32_t filenumber, uint64_t position, const uint8_t *data,
              uint16_t length)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    if (m->friendlist[friendnumber].status != FRIEND_ONLINE) {
        return -2;
    }

    if (filenumber >= MAX_CONCURRENT_FILE_PIPES) {
        return -3;
    }

    struct File_Transfers *ft = &m->friendlist[friendnumber].file_sending[filenumber];

    if (ft->status != FILESTATUS_TRANSFERRING) {
        return -4;
    }

    if (length > MAX_FILE_DATA_SIZE) {
        return -5;
    }

    if (ft->size - ft->transferred < length) {
        return -5;
    }

    if (ft->size != UINT64_MAX && length != MAX_FILE_DATA_SIZE && (ft->transferred + length) != ft->size) {
        return -5;
    }

    if (position != ft->transferred || (ft->requested <= position && ft->size != 0)) {
        return -7;
    }

    /* Prevent file sending from filling up the entire buffer preventing messages from being sent.
     * TODO(irungentoo): remove */
    if (crypto_num_free_sendqueue_slots(m->net_crypto, friend_connection_crypt_connection_id(m->fr_c,
                                        m->friendlist[friendnumber].friendcon_id)) < MIN_SLOTS_FREE) {
        return -6;
    }

    int64_t ret = send_file_data_packet(m, friendnumber, filenumber, data, length);

    if (ret != -1) {
        // TODO(irungentoo): record packet ids to check if other received complete file.
        ft->transferred += length;

        if (ft->slots_allocated) {
            --ft->slots_allocated;
        }

        if (length != MAX_FILE_DATA_SIZE || ft->size == ft->transferred) {
            ft->status = FILESTATUS_FINISHED;
            ft->last_packet_number = ret;
        }

        return 0;
    }

    return -6;
}

/* Give the number of bytes left to be sent/received.
 *
 *  send_receive is 0 if we want the sending files, 1 if we want the receiving.
 *
 *  return number of bytes remaining to be sent/received on success
 *  return 0 on failure
 */
uint64_t file_dataremaining(const Messenger *m, int32_t friendnumber, uint8_t filenumber, uint8_t send_receive)
{
    if (friend_not_valid(m, friendnumber)) {
        return 0;
    }

    const struct File_Transfers *const sending = &m->friendlist[friendnumber].file_sending[filenumber];

    if (send_receive == 0) {
        if (sending->status == FILESTATUS_NONE) {
            return 0;
        }

        return sending->size - sending->transferred;
    }

    const struct File_Transfers *const receiving = &m->friendlist[friendnumber].file_receiving[filenumber];

    if (receiving->status == FILESTATUS_NONE) {
        return 0;
    }

    return receiving->size - receiving->transferred;
}

/**
 * Iterate over all file transfers and request chunks (from the client) for each
 * of them.
 *
 * The free_slots parameter is updated by this function.
 *
 * @param m Our messenger object.
 * @param friendnumber The friend we're sending files to.
 * @param userdata The client userdata to pass along to chunk request callbacks.
 * @param free_slots A pointer to the number of free send queue slots in the
 *   crypto connection.
 *
 * @return true if there are still file transfers ongoing, false if all file
 *   transfers are complete.
 */
static bool do_all_filetransfers(Messenger *m, int32_t friendnumber, void *userdata, uint32_t *free_slots)
{
    Friend *const friendcon = &m->friendlist[friendnumber];
    uint32_t num = friendcon->num_sending_files;

    bool any_active_fts = false;

    // Iterate over all file transfers, including inactive ones. I.e. we always
    // iterate exactly MAX_CONCURRENT_FILE_PIPES times.
    for (uint32_t i = 0; i < MAX_CONCURRENT_FILE_PIPES; ++i) {
        struct File_Transfers *const ft = &friendcon->file_sending[i];

        // Any status other than NONE means the file transfer is active.
        if (ft->status != FILESTATUS_NONE) {
            any_active_fts = true;
            --num;

            // If the file transfer is complete, we request a chunk of size 0.
            if (ft->status == FILESTATUS_FINISHED && friend_received_packet(m, friendnumber, ft->last_packet_number) == 0) {
                if (m->file_reqchunk) {
                    m->file_reqchunk(m, friendnumber, i, ft->transferred, 0, userdata);
                }

                // Now it's inactive, we're no longer sending this.
                ft->status = FILESTATUS_NONE;
                --friendcon->num_sending_files;
            }

            // Decrease free slots by the number of slots this FT uses.
            *free_slots = max_s32(0, (int32_t) * free_slots - ft->slots_allocated);
        }

        if (ft->status == FILESTATUS_TRANSFERRING && ft->paused == FILE_PAUSE_NOT) {
            if (max_speed_reached(m->net_crypto, friend_connection_crypt_connection_id(
                                      m->fr_c, friendcon->friendcon_id))) {
                *free_slots = 0;
            }

            if (*free_slots == 0) {
                continue;
            }

            if (ft->size == 0) {
                /* Send 0 data to friend if file is 0 length. */
                file_data(m, friendnumber, i, 0, nullptr, 0);
                continue;
            }

            if (ft->size == ft->requested) {
                // This file transfer is done.
                continue;
            }

            // Allocate 1 slot to this file transfer.
            ft->slots_allocated++;

            const uint16_t length = min_u64(ft->size - ft->requested, MAX_FILE_DATA_SIZE);
            const uint64_t position = ft->requested;
            ft->requested += length;

            if (m->file_reqchunk) {
                m->file_reqchunk(m, friendnumber, i, position, length, userdata);
            }

            // The allocated slot is no longer free.
            --*free_slots;
        }

        if (num == 0) {
            continue;
        }
    }

    return any_active_fts;
}

static void do_reqchunk_filecb(Messenger *m, int32_t friendnumber, void *userdata)
{
    // We're not currently doing any file transfers.
    if (m->friendlist[friendnumber].num_sending_files == 0) {
        return;
    }

    // The number of packet slots left in the sendbuffer.
    // This is a per friend count (CRYPTO_PACKET_BUFFER_SIZE).
    uint32_t free_slots = crypto_num_free_sendqueue_slots(
                              m->net_crypto,
                              friend_connection_crypt_connection_id(
                                  m->fr_c,
                                  m->friendlist[friendnumber].friendcon_id));

    // We keep MIN_SLOTS_FREE slots free for other packets, otherwise file
    // transfers might block other traffic for a long time.
    free_slots = max_s32(0, (int32_t)free_slots - MIN_SLOTS_FREE);

    bool any_active_fts = true;
    uint32_t loop_counter = 0;
    // Maximum number of outer loops below. If the client doesn't send file
    // chunks from within the chunk request callback handler, we never realise
    // that the file transfer has finished and may end up in an infinite loop.
    //
    // TODO(zoff99): Fix this to exit the loop properly when we're done
    // requesting all chunks for all file transfers.
    const uint32_t MAX_FT_LOOPS = 4;

    while (((free_slots > 0) || loop_counter == 0) && any_active_fts && (loop_counter < MAX_FT_LOOPS)) {
        any_active_fts = do_all_filetransfers(m, friendnumber, userdata, &free_slots);
        loop_counter++;
    }
}


/* Run this when the friend disconnects.
 *  Kill all current file transfers.
 */
static void break_files(const Messenger *m, int32_t friendnumber)
{
    // TODO(irungentoo): Inform the client which file transfers get killed with a callback?
    for (uint32_t i = 0; i < MAX_CONCURRENT_FILE_PIPES; ++i) {
        if (m->friendlist[friendnumber].file_sending[i].status != FILESTATUS_NONE) {
            m->friendlist[friendnumber].file_sending[i].status = FILESTATUS_NONE;
        }

        if (m->friendlist[friendnumber].file_receiving[i].status != FILESTATUS_NONE) {
            m->friendlist[friendnumber].file_receiving[i].status = FILESTATUS_NONE;
        }
    }
}

static struct File_Transfers *get_file_transfer(uint8_t receive_send, uint8_t filenumber,
        uint32_t *real_filenumber, Friend *sender)
{
    struct File_Transfers *ft;

    if (receive_send == 0) {
        *real_filenumber = (filenumber + 1) << 16;
        ft = &sender->file_receiving[filenumber];
    } else {
        *real_filenumber = filenumber;
        ft = &sender->file_sending[filenumber];
    }

    if (ft->status == FILESTATUS_NONE) {
        return nullptr;
    }

    return ft;
}

/* return -1 on failure, 0 on success.
 */
static int handle_filecontrol(Messenger *m, int32_t friendnumber, uint8_t receive_send, uint8_t filenumber,
                              uint8_t control_type, const uint8_t *data, uint16_t length, void *userdata)
{
    if (receive_send > 1) {
        LOGGER_DEBUG(m->log, "file control (friend %d, file %d): receive_send value is invalid (should be 0 or 1): %d",
                     friendnumber, filenumber, receive_send);
        return -1;
    }

    uint32_t real_filenumber;
    struct File_Transfers *ft = get_file_transfer(receive_send, filenumber, &real_filenumber, &m->friendlist[friendnumber]);

    if (ft == nullptr) {
        LOGGER_DEBUG(m->log, "file control (friend %d, file %d): file transfer does not exist; telling the other to kill it",
                     friendnumber, filenumber);
        send_file_control_packet(m, friendnumber, !receive_send, filenumber, FILECONTROL_KILL, nullptr, 0);
        return -1;
    }

    switch (control_type) {
        case FILECONTROL_ACCEPT: {
            if (receive_send && ft->status == FILESTATUS_NOT_ACCEPTED) {
                ft->status = FILESTATUS_TRANSFERRING;
            } else {
                if (ft->paused & FILE_PAUSE_OTHER) {
                    ft->paused ^= FILE_PAUSE_OTHER;
                } else {
                    LOGGER_DEBUG(m->log, "file control (friend %d, file %d): friend told us to resume file transfer that wasn't paused",
                                 friendnumber, filenumber);
                    return -1;
                }
            }

            if (m->file_filecontrol) {
                m->file_filecontrol(m, friendnumber, real_filenumber, control_type, userdata);
            }

            return 0;
        }

        case FILECONTROL_PAUSE: {
            if ((ft->paused & FILE_PAUSE_OTHER) || ft->status != FILESTATUS_TRANSFERRING) {
                LOGGER_DEBUG(m->log, "file control (friend %d, file %d): friend told us to pause file transfer that is already paused",
                             friendnumber, filenumber);
                return -1;
            }

            ft->paused |= FILE_PAUSE_OTHER;

            if (m->file_filecontrol) {
                m->file_filecontrol(m, friendnumber, real_filenumber, control_type, userdata);
            }

            return 0;
        }

        case FILECONTROL_KILL: {
            if (m->file_filecontrol) {
                m->file_filecontrol(m, friendnumber, real_filenumber, control_type, userdata);
            }

            ft->status = FILESTATUS_NONE;

            if (receive_send) {
                --m->friendlist[friendnumber].num_sending_files;
            }

            return 0;
        }

        case FILECONTROL_SEEK: {
            uint64_t position;

            if (length != sizeof(position)) {
                LOGGER_DEBUG(m->log, "file control (friend %d, file %d): expected payload of length %d, but got %d",
                             friendnumber, filenumber, (uint32_t)sizeof(position), length);
                return -1;
            }

            /* seek can only be sent by the receiver to seek before resuming broken transfers. */
            if (ft->status != FILESTATUS_NOT_ACCEPTED || !receive_send) {
                LOGGER_DEBUG(m->log,
                             "file control (friend %d, file %d): seek was either sent by a sender or by the receiver after accepting",
                             friendnumber, filenumber);
                return -1;
            }

            memcpy(&position, data, sizeof(position));
            net_to_host((uint8_t *) &position, sizeof(position));

            if (position >= ft->size) {
                LOGGER_DEBUG(m->log,
                             "file control (friend %d, file %d): seek position %lld exceeds file size %lld",
                             friendnumber, filenumber, (unsigned long long)position, (unsigned long long)ft->size);
                return -1;
            }

            ft->transferred = ft->requested = position;
            return 0;
        }

        default: {
            LOGGER_DEBUG(m->log, "file control (friend %d, file %d): invalid file control: %d",
                         friendnumber, filenumber, control_type);
            return -1;
        }
    }
}

/**************************************/

/* Set the callback for msi packets.
 *
 *  Function(Messenger *m, int friendnumber, uint8_t *data, uint16_t length, void *userdata)
 */
void m_callback_msi_packet(Messenger *m, void (*function)(Messenger *m, uint32_t, const uint8_t *, uint16_t, void *),
                           void *userdata)
{
    m->msi_packet = function;
    m->msi_packet_userdata = userdata;
}

/* Send an msi packet.
 *
 *  return 1 on success
 *  return 0 on failure
 */
int m_msi_packet(const Messenger *m, int32_t friendnumber, const uint8_t *data, uint16_t length)
{
    return write_cryptpacket_id(m, friendnumber, PACKET_ID_MSI, data, length, 0);
}

static int m_handle_custom_lossy_packet(void *object, int friend_num, const uint8_t *packet, uint16_t length,
                                        void *userdata)
{
    Messenger *m = (Messenger *)object;

    if (friend_not_valid(m, friend_num)) {
        return 1;
    }

    if (packet[0] < (PACKET_ID_LOSSY_RANGE_START + PACKET_LOSSY_AV_RESERVED)) {
        if (m->friendlist[friend_num].lossy_rtp_packethandlers[packet[0] % PACKET_LOSSY_AV_RESERVED].function) {
            return m->friendlist[friend_num].lossy_rtp_packethandlers[packet[0] % PACKET_LOSSY_AV_RESERVED].function(
                       m, friend_num, packet, length, m->friendlist[friend_num].lossy_rtp_packethandlers[packet[0] %
                               PACKET_LOSSY_AV_RESERVED].object);
        }

        return 1;
    }

    if (m->lossy_packethandler) {
        m->lossy_packethandler(m, friend_num, packet, length, userdata);
    }

    return 1;
}

void custom_lossy_packet_registerhandler(Messenger *m, void (*lossy_packethandler)(Messenger *m,
        uint32_t friendnumber, const uint8_t *data, size_t len, void *object))
{
    m->lossy_packethandler = lossy_packethandler;
}

int m_callback_rtp_packet(Messenger *m, int32_t friendnumber, uint8_t byte, int (*function)(Messenger *m,
                          uint32_t friendnumber, const uint8_t *data, uint16_t len, void *object), void *object)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    if (byte < PACKET_ID_LOSSY_RANGE_START) {
        return -1;
    }

    if (byte >= (PACKET_ID_LOSSY_RANGE_START + PACKET_LOSSY_AV_RESERVED)) {
        return -1;
    }

    m->friendlist[friendnumber].lossy_rtp_packethandlers[byte % PACKET_LOSSY_AV_RESERVED].function = function;
    m->friendlist[friendnumber].lossy_rtp_packethandlers[byte % PACKET_LOSSY_AV_RESERVED].object = object;
    return 0;
}


int m_send_custom_lossy_packet(const Messenger *m, int32_t friendnumber, const uint8_t *data, uint32_t length)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    if (length == 0 || length > MAX_CRYPTO_DATA_SIZE) {
        return -2;
    }

    if (data[0] < PACKET_ID_LOSSY_RANGE_START) {
        return -3;
    }

    if (data[0] >= (PACKET_ID_LOSSY_RANGE_START + PACKET_ID_LOSSY_RANGE_SIZE)) {
        return -3;
    }

    if (m->friendlist[friendnumber].status != FRIEND_ONLINE) {
        return -4;
    }

    if (send_lossy_cryptpacket(m->net_crypto, friend_connection_crypt_connection_id(m->fr_c,
                               m->friendlist[friendnumber].friendcon_id), data, length) == -1) {
        return -5;
    }

    return 0;
}

static int handle_custom_lossless_packet(void *object, int friend_num, const uint8_t *packet, uint16_t length,
        void *userdata)
{
    Messenger *m = (Messenger *)object;

    if (friend_not_valid(m, friend_num)) {
        return -1;
    }

    if (packet[0] < PACKET_ID_LOSSLESS_RANGE_START) {
        return -1;
    }

    if (packet[0] >= (PACKET_ID_LOSSLESS_RANGE_START + PACKET_ID_LOSSLESS_RANGE_SIZE)) {
        return -1;
    }

    if (m->lossless_packethandler) {
        m->lossless_packethandler(m, friend_num, packet, length, userdata);
    }

    return 1;
}

void custom_lossless_packet_registerhandler(Messenger *m, void (*lossless_packethandler)(Messenger *m,
        uint32_t friendnumber, const uint8_t *data, size_t len, void *object))
{
    m->lossless_packethandler = lossless_packethandler;
}

int send_custom_lossless_packet(const Messenger *m, int32_t friendnumber, const uint8_t *data, uint32_t length)
{
    if (friend_not_valid(m, friendnumber)) {
        return -1;
    }

    if (length == 0 || length > MAX_CRYPTO_DATA_SIZE) {
        return -2;
    }

    if (data[0] < PACKET_ID_LOSSLESS_RANGE_START) {
        return -3;
    }

    if (data[0] >= (PACKET_ID_LOSSLESS_RANGE_START + PACKET_ID_LOSSLESS_RANGE_SIZE)) {
        return -3;
    }

    if (m->friendlist[friendnumber].status != FRIEND_ONLINE) {
        return -4;
    }

    if (write_cryptpacket(m->net_crypto, friend_connection_crypt_connection_id(m->fr_c,
                          m->friendlist[friendnumber].friendcon_id), data, length, 1) == -1) {
        return -5;
    }

    return 0;
}

/* Function to filter out some friend requests*/
static int friend_already_added(const uint8_t *real_pk, void *data)
{
    const Messenger *m = (const Messenger *)data;

    if (getfriend_id(m, real_pk) == -1) {
        return 0;
    }

    return -1;
}

/* Run this at startup. */
Messenger *new_messenger(Messenger_Options *options, unsigned int *error)
{
    if (!options) {
        return nullptr;
    }

    if (error) {
        *error = MESSENGER_ERROR_OTHER;
    }

    Messenger *m = (Messenger *)calloc(1, sizeof(Messenger));

    if (!m) {
        return nullptr;
    }

    m->fr = friendreq_new();

    if (!m->fr) {
        free(m);
        return nullptr;
    }

    Logger *log = nullptr;

    if (options->log_callback) {
        log = logger_new();

        if (log != nullptr) {
            logger_callback_log(log, options->log_callback, m, options->log_user_data);
        }
    }

    m->log = log;

    unsigned int net_err = 0;

    if (options->udp_disabled) {
        m->net = new_networking_no_udp(log);
    } else {
        IP ip;
        ip_init(&ip, options->ipv6enabled);
        m->net = new_networking_ex(log, ip, options->port_range[0], options->port_range[1], &net_err);
    }

    if (m->net == nullptr) {
        friendreq_kill(m->fr);
        logger_kill(m->log);
        free(m);

        if (error && net_err == 1) {
            *error = MESSENGER_ERROR_PORT;
        }

        return nullptr;
    }

    m->dht = new_DHT(m->log, m->net, options->hole_punching_enabled);

    if (m->dht == nullptr) {
        kill_networking(m->net);
        friendreq_kill(m->fr);
        logger_kill(m->log);
        free(m);
        return nullptr;
    }

    m->net_crypto = new_net_crypto(m->log, m->dht, &options->proxy_info);

    if (m->net_crypto == nullptr) {
        kill_networking(m->net);
        kill_DHT(m->dht);
        friendreq_kill(m->fr);
        logger_kill(m->log);
        free(m);
        return nullptr;
    }

    m->onion = new_onion(m->dht);
    m->onion_a = new_onion_announce(m->dht);
    m->onion_c =  new_onion_client(m->net_crypto);
    m->fr_c = new_friend_connections(m->onion_c, options->local_discovery_enabled);

    if (!(m->onion && m->onion_a && m->onion_c)) {
        kill_friend_connections(m->fr_c);
        kill_onion(m->onion);
        kill_onion_announce(m->onion_a);
        kill_onion_client(m->onion_c);
        kill_net_crypto(m->net_crypto);
        kill_DHT(m->dht);
        kill_networking(m->net);
        friendreq_kill(m->fr);
        logger_kill(m->log);
        free(m);
        return nullptr;
    }

    if (options->tcp_server_port) {
        m->tcp_server = new_TCP_server(options->ipv6enabled, 1, &options->tcp_server_port, dht_get_self_secret_key(m->dht),
                                       m->onion);

        if (m->tcp_server == nullptr) {
            kill_friend_connections(m->fr_c);
            kill_onion(m->onion);
            kill_onion_announce(m->onion_a);
            kill_onion_client(m->onion_c);
            kill_net_crypto(m->net_crypto);
            kill_DHT(m->dht);
            kill_networking(m->net);
            friendreq_kill(m->fr);
            logger_kill(m->log);
            free(m);

            if (error) {
                *error = MESSENGER_ERROR_TCP_SERVER;
            }

            return nullptr;
        }
    }

    m->options = *options;
    friendreq_init(m->fr, m->fr_c);
    set_nospam(m->fr, random_u32());
    set_filter_function(m->fr, &friend_already_added, m);

    m->lastdump = 0;

    if (error) {
        *error = MESSENGER_ERROR_NONE;
    }

    return m;
}

/* Run this before closing shop. */
void kill_messenger(Messenger *m)
{
    if (!m) {
        return;
    }

    uint32_t i;

    if (m->tcp_server) {
        kill_TCP_server(m->tcp_server);
    }

    kill_friend_connections(m->fr_c);
    kill_onion(m->onion);
    kill_onion_announce(m->onion_a);
    kill_onion_client(m->onion_c);
    kill_net_crypto(m->net_crypto);
    kill_DHT(m->dht);
    kill_networking(m->net);

    for (i = 0; i < m->numfriends; ++i) {
        clear_receipts(m, i);
    }

    logger_kill(m->log);
    free(m->friendlist);
    friendreq_kill(m->fr);
    free(m);
}

/* Check for and handle a timed-out friend request. If the request has
 * timed-out then the friend status is set back to FRIEND_ADDED.
 *   i: friendlist index of the timed-out friend
 *   t: time
 */
static void check_friend_request_timed_out(Messenger *m, uint32_t i, uint64_t t, void *userdata)
{
    Friend *f = &m->friendlist[i];

    if (f->friendrequest_lastsent + f->friendrequest_timeout < t) {
        set_friend_status(m, i, FRIEND_ADDED, userdata);
        /* Double the default timeout every time if friendrequest is assumed
         * to have been sent unsuccessfully.
         */
        f->friendrequest_timeout *= 2;
    }
}

static int m_handle_status(void *object, int i, uint8_t status, void *userdata)
{
    Messenger *m = (Messenger *)object;

    if (status) { /* Went online. */
        send_online_packet(m, i);
    } else { /* Went offline. */
        if (m->friendlist[i].status == FRIEND_ONLINE) {
            set_friend_status(m, i, FRIEND_CONFIRMED, userdata);
        }
    }

    return 0;
}

static int m_handle_packet(void *object, int i, const uint8_t *temp, uint16_t len, void *userdata)
{
    if (len == 0) {
        return -1;
    }

    Messenger *m = (Messenger *)object;
    uint8_t packet_id = temp[0];
    const uint8_t *data = temp + 1;
    uint32_t data_length = len - 1;

    if (m->friendlist[i].status != FRIEND_ONLINE) {
        if (packet_id == PACKET_ID_ONLINE && len == 1) {
            set_friend_status(m, i, FRIEND_ONLINE, userdata);
            send_online_packet(m, i);
        } else {
            return -1;
        }
    }

    switch (packet_id) {
        case PACKET_ID_OFFLINE: {
            if (data_length != 0) {
                break;
            }

            set_friend_status(m, i, FRIEND_CONFIRMED, userdata);
            break;
        }

        case PACKET_ID_NICKNAME: {
            if (data_length > MAX_NAME_LENGTH) {
                break;
            }

            /* Make sure the NULL terminator is present. */
            VLA(uint8_t, data_terminated, data_length + 1);
            memcpy(data_terminated, data, data_length);
            data_terminated[data_length] = 0;

            /* inform of namechange before we overwrite the old name */
            if (m->friend_namechange) {
                m->friend_namechange(m, i, data_terminated, data_length, userdata);
            }

            memcpy(m->friendlist[i].name, data_terminated, data_length);
            m->friendlist[i].name_length = data_length;

            break;
        }

        case PACKET_ID_STATUSMESSAGE: {
            if (data_length > MAX_STATUSMESSAGE_LENGTH) {
                break;
            }

            /* Make sure the NULL terminator is present. */
            VLA(uint8_t, data_terminated, data_length + 1);
            memcpy(data_terminated, data, data_length);
            data_terminated[data_length] = 0;

            if (m->friend_statusmessagechange) {
                m->friend_statusmessagechange(m, i, data_terminated, data_length, userdata);
            }

            set_friend_statusmessage(m, i, data_terminated, data_length);
            break;
        }

        case PACKET_ID_USERSTATUS: {
            if (data_length != 1) {
                break;
            }

            USERSTATUS status = (USERSTATUS)data[0];

            if (status >= USERSTATUS_INVALID) {
                break;
            }

            if (m->friend_userstatuschange) {
                m->friend_userstatuschange(m, i, status, userdata);
            }

            set_friend_userstatus(m, i, status);
            break;
        }

        case PACKET_ID_TYPING: {
            if (data_length != 1) {
                break;
            }

            bool typing = !!data[0];

            set_friend_typing(m, i, typing);

            if (m->friend_typingchange) {
                m->friend_typingchange(m, i, typing, userdata);
            }

            break;
        }

        case PACKET_ID_MESSAGE: // fall-through
        case PACKET_ID_ACTION: {
            if (data_length == 0) {
                break;
            }

            const uint8_t *message = data;
            uint16_t message_length = data_length;

            /* Make sure the NULL terminator is present. */
            VLA(uint8_t, message_terminated, message_length + 1);
            memcpy(message_terminated, message, message_length);
            message_terminated[message_length] = 0;
            uint8_t type = packet_id - PACKET_ID_MESSAGE;

            if (m->friend_message) {
                (*m->friend_message)(m, i, type, message_terminated, message_length, userdata);
            }

            break;
        }

        case PACKET_ID_INVITE_CONFERENCE: {
            if (data_length == 0) {
                break;
            }

            if (m->conference_invite) {
                (*m->conference_invite)(m, i, data, data_length, userdata);
            }

            break;
        }

        case PACKET_ID_FILE_SENDREQUEST: {
            const unsigned int head_length = 1 + sizeof(uint32_t) + sizeof(uint64_t) + FILE_ID_LENGTH;

            if (data_length < head_length) {
                break;
            }

            uint8_t filenumber = data[0];

#if UINT8_MAX >= MAX_CONCURRENT_FILE_PIPES

            if (filenumber >= MAX_CONCURRENT_FILE_PIPES) {
                break;
            }

#endif

            uint64_t filesize;
            uint32_t file_type;
            uint16_t filename_length = data_length - head_length;

            if (filename_length > MAX_FILENAME_LENGTH) {
                break;
            }

            memcpy(&file_type, data + 1, sizeof(file_type));
            file_type = net_ntohl(file_type);

            memcpy(&filesize, data + 1 + sizeof(uint32_t), sizeof(filesize));
            net_to_host((uint8_t *) &filesize, sizeof(filesize));
            struct File_Transfers *ft = &m->friendlist[i].file_receiving[filenumber];

            if (ft->status != FILESTATUS_NONE) {
                break;
            }

            ft->status = FILESTATUS_NOT_ACCEPTED;
            ft->size = filesize;
            ft->transferred = 0;
            ft->paused = FILE_PAUSE_NOT;
            memcpy(ft->id, data + 1 + sizeof(uint32_t) + sizeof(uint64_t), FILE_ID_LENGTH);

            VLA(uint8_t, filename_terminated, filename_length + 1);
            uint8_t *filename = nullptr;

            if (filename_length) {
                /* Force NULL terminate file name. */
                memcpy(filename_terminated, data + head_length, filename_length);
                filename_terminated[filename_length] = 0;
                filename = filename_terminated;
            }

            uint32_t real_filenumber = filenumber;
            real_filenumber += 1;
            real_filenumber <<= 16;

            if (m->file_sendrequest) {
                (*m->file_sendrequest)(m, i, real_filenumber, file_type, filesize, filename, filename_length,
                                       userdata);
            }

            break;
        }

        case PACKET_ID_FILE_CONTROL: {
            if (data_length < 3) {
                break;
            }

            uint8_t send_receive = data[0];
            uint8_t filenumber = data[1];
            uint8_t control_type = data[2];

#if UINT8_MAX >= MAX_CONCURRENT_FILE_PIPES

            if (filenumber >= MAX_CONCURRENT_FILE_PIPES) {
                break;
            }

#endif

            if (handle_filecontrol(m, i, send_receive, filenumber, control_type, data + 3, data_length - 3, userdata) == -1) {
                // TODO(iphydf): Do something different here? Right now, this
                // check is pointless.
                break;
            }

            break;
        }

        case PACKET_ID_FILE_DATA: {
            if (data_length < 1) {
                break;
            }

            uint8_t filenumber = data[0];

#if UINT8_MAX >= MAX_CONCURRENT_FILE_PIPES

            if (filenumber >= MAX_CONCURRENT_FILE_PIPES) {
                break;
            }

#endif

            struct File_Transfers *ft = &m->friendlist[i].file_receiving[filenumber];

            if (ft->status != FILESTATUS_TRANSFERRING) {
                break;
            }

            uint64_t position = ft->transferred;
            uint32_t real_filenumber = filenumber;
            real_filenumber += 1;
            real_filenumber <<= 16;
            uint16_t file_data_length = (data_length - 1);
            const uint8_t *file_data;

            if (file_data_length == 0) {
                file_data = nullptr;
            } else {
                file_data = data + 1;
            }

            /* Prevent more data than the filesize from being passed to clients. */
            if ((ft->transferred + file_data_length) > ft->size) {
                file_data_length = ft->size - ft->transferred;
            }

            if (m->file_filedata) {
                (*m->file_filedata)(m, i, real_filenumber, position, file_data, file_data_length, userdata);
            }

            ft->transferred += file_data_length;

            if (file_data_length && (ft->transferred >= ft->size || file_data_length != MAX_FILE_DATA_SIZE)) {
                file_data_length = 0;
                file_data = nullptr;
                position = ft->transferred;

                /* Full file received. */
                if (m->file_filedata) {
                    (*m->file_filedata)(m, i, real_filenumber, position, file_data, file_data_length, userdata);
                }
            }

            /* Data is zero, filetransfer is over. */
            if (file_data_length == 0) {
                ft->status = FILESTATUS_NONE;
            }

            break;
        }

        case PACKET_ID_MSI: {
            if (data_length == 0) {
                break;
            }

            if (m->msi_packet) {
                (*m->msi_packet)(m, i, data, data_length, m->msi_packet_userdata);
            }

            break;
        }

        default: {
            handle_custom_lossless_packet(object, i, temp, len, userdata);
            break;
        }
    }

    return 0;
}

static void do_friends(Messenger *m, void *userdata)
{
    uint32_t i;
    uint64_t temp_time = unix_time();

    for (i = 0; i < m->numfriends; ++i) {
        if (m->friendlist[i].status == FRIEND_ADDED) {
            int fr = send_friend_request_packet(m->fr_c, m->friendlist[i].friendcon_id, m->friendlist[i].friendrequest_nospam,
                                                m->friendlist[i].info,
                                                m->friendlist[i].info_size);

            if (fr >= 0) {
                set_friend_status(m, i, FRIEND_REQUESTED, userdata);
                m->friendlist[i].friendrequest_lastsent = temp_time;
            }
        }

        if (m->friendlist[i].status == FRIEND_REQUESTED
                || m->friendlist[i].status == FRIEND_CONFIRMED) { /* friend is not online. */
            if (m->friendlist[i].status == FRIEND_REQUESTED) {
                /* If we didn't connect to friend after successfully sending him a friend request the request is deemed
                 * unsuccessful so we set the status back to FRIEND_ADDED and try again.
                 */
                check_friend_request_timed_out(m, i, temp_time, userdata);
            }
        }

        if (m->friendlist[i].status == FRIEND_ONLINE) { /* friend is online. */
            if (m->friendlist[i].name_sent == 0) {
                if (m_sendname(m, i, m->name, m->name_length)) {
                    m->friendlist[i].name_sent = 1;
                }
            }

            if (m->friendlist[i].statusmessage_sent == 0) {
                if (send_statusmessage(m, i, m->statusmessage, m->statusmessage_length)) {
                    m->friendlist[i].statusmessage_sent = 1;
                }
            }

            if (m->friendlist[i].userstatus_sent == 0) {
                if (send_userstatus(m, i, m->userstatus)) {
                    m->friendlist[i].userstatus_sent = 1;
                }
            }

            if (m->friendlist[i].user_istyping_sent == 0) {
                if (send_user_istyping(m, i, m->friendlist[i].user_istyping)) {
                    m->friendlist[i].user_istyping_sent = 1;
                }
            }

            check_friend_tcp_udp(m, i, userdata);
            do_receipts(m, i, userdata);
            do_reqchunk_filecb(m, i, userdata);

            m->friendlist[i].last_seen_time = (uint64_t) time(nullptr);
        }
    }
}

static void connection_status_cb(Messenger *m, void *userdata)
{
    unsigned int conn_status = onion_connection_status(m->onion_c);

    if (conn_status != m->last_connection_status) {
        if (m->core_connection_change) {
            (*m->core_connection_change)(m, conn_status, userdata);
        }

        m->last_connection_status = conn_status;
    }
}


#define DUMPING_CLIENTS_FRIENDS_EVERY_N_SECONDS 60UL

#define IDSTRING_LEN (CRYPTO_PUBLIC_KEY_SIZE * 2 + 1)
/* id_str should be of length at least IDSTRING_LEN */
static char *id_to_string(const uint8_t *pk, char *id_str, size_t length)
{
    if (length < IDSTRING_LEN) {
        snprintf(id_str, length, "Bad buf length");
        return id_str;
    }

    for (uint32_t i = 0; i < CRYPTO_PUBLIC_KEY_SIZE; i++) {
        sprintf(&id_str[i * 2], "%02X", pk[i]);
    }

    id_str[CRYPTO_PUBLIC_KEY_SIZE * 2] = 0;
    return id_str;
}

/* Minimum messenger run interval in ms
   TODO(mannol): A/V */
#define MIN_RUN_INTERVAL 50

/* Return the time in milliseconds before do_messenger() should be called again
 * for optimal performance.
 *
 * returns time (in ms) before the next do_messenger() needs to be run on success.
 */
uint32_t messenger_run_interval(const Messenger *m)
{
    uint32_t crypto_interval = crypto_run_interval(m->net_crypto);

    if (crypto_interval > MIN_RUN_INTERVAL) {
        return MIN_RUN_INTERVAL;
    }

    return crypto_interval;
}

/* The main loop that needs to be run at least 20 times per second. */
void do_messenger(Messenger *m, void *userdata)
{
    // Add the TCP relays, but only if this is the first time calling do_messenger
    if (m->has_added_relays == 0) {
        m->has_added_relays = 1;

        int i;

        for (i = 0; i < NUM_SAVED_TCP_RELAYS; ++i) {
            add_tcp_relay(m->net_crypto, m->loaded_relays[i].ip_port, m->loaded_relays[i].public_key);
        }

        if (m->tcp_server) {
            /* Add self tcp server. */
            IP_Port local_ip_port;
            local_ip_port.port = m->options.tcp_server_port;
            local_ip_port.ip.family = TOX_AF_INET;
            local_ip_port.ip.ip.v4 = get_ip4_loopback();
            add_tcp_relay(m->net_crypto, local_ip_port,
                          tcp_server_public_key(m->tcp_server));
        }
    }

    unix_time_update();

    if (!m->options.udp_disabled) {
        networking_poll(m->net, userdata);
        do_DHT(m->dht);
    }

    if (m->tcp_server) {
        do_TCP_server(m->tcp_server);
    }

    do_net_crypto(m->net_crypto, userdata);
    do_onion_client(m->onion_c);
    do_friend_connections(m->fr_c, userdata);
    do_friends(m, userdata);
    connection_status_cb(m, userdata);

    if (unix_time() > m->lastdump + DUMPING_CLIENTS_FRIENDS_EVERY_N_SECONDS) {
        m->lastdump = unix_time();
        uint32_t client, last_pinged;

        for (client = 0; client < LCLIENT_LIST; client++) {
            const Client_data *cptr = dht_get_close_client(m->dht, client);
            const IPPTsPng *assoc = nullptr;
            uint32_t a;

            for (a = 0, assoc = &cptr->assoc4; a < 2; a++, assoc = &cptr->assoc6) {
                if (ip_isset(&assoc->ip_port.ip)) {
                    last_pinged = m->lastdump - assoc->last_pinged;

                    if (last_pinged > 999) {
                        last_pinged = 999;
                    }

                    char ip_str[IP_NTOA_LEN];
                    char id_str[IDSTRING_LEN];
                    LOGGER_TRACE(m->log, "C[%2u] %s:%u [%3u] %s",
                                 client, ip_ntoa(&assoc->ip_port.ip, ip_str, sizeof(ip_str)),
                                 net_ntohs(assoc->ip_port.port), last_pinged,
                                 id_to_string(cptr->public_key, id_str, sizeof(id_str)));
                }
            }
        }


        uint32_t friend_idx, dhtfriend;

        /* dht contains additional "friends" (requests) */
        uint32_t num_dhtfriends = dht_get_num_friends(m->dht);
        VLA(int32_t, m2dht, num_dhtfriends);
        VLA(int32_t, dht2m, num_dhtfriends);

        for (friend_idx = 0; friend_idx < num_dhtfriends; friend_idx++) {
            m2dht[friend_idx] = -1;
            dht2m[friend_idx] = -1;

            if (friend_idx >= m->numfriends) {
                continue;
            }

            for (dhtfriend = 0; dhtfriend < dht_get_num_friends(m->dht); dhtfriend++) {
                if (id_equal(m->friendlist[friend_idx].real_pk, dht_get_friend_public_key(m->dht, dhtfriend))) {
                    m2dht[friend_idx] = dhtfriend;
                    break;
                }
            }
        }

        for (friend_idx = 0; friend_idx < num_dhtfriends; friend_idx++) {
            if (m2dht[friend_idx] >= 0) {
                dht2m[m2dht[friend_idx]] = friend_idx;
            }
        }

        if (m->numfriends != dht_get_num_friends(m->dht)) {
            LOGGER_TRACE(m->log, "Friend num in DHT %u != friend num in msger %u\n", dht_get_num_friends(m->dht), m->numfriends);
        }

        Friend *msgfptr;
        DHT_Friend *dhtfptr;

        for (friend_idx = 0; friend_idx < num_dhtfriends; friend_idx++) {
            if (dht2m[friend_idx] >= 0) {
                msgfptr = &m->friendlist[dht2m[friend_idx]];
            } else {
                msgfptr = nullptr;
            }

            dhtfptr = dht_get_friend(m->dht, friend_idx);

            if (msgfptr) {
                char id_str[IDSTRING_LEN];
                LOGGER_TRACE(m->log, "F[%2u:%2u] <%s> %s",
                             dht2m[friend_idx], friend_idx, msgfptr->name,
                             id_to_string(msgfptr->real_pk, id_str, sizeof(id_str)));
            } else {
                char id_str[IDSTRING_LEN];
                LOGGER_TRACE(m->log, "F[--:%2u] %s", friend_idx,
                             id_to_string(dhtfptr->public_key, id_str, sizeof(id_str)));
            }

            for (client = 0; client < MAX_FRIEND_CLIENTS; client++) {
                Client_data *cptr = &dhtfptr->client_list[client];
                IPPTsPng *assoc = nullptr;
                uint32_t a;

                for (a = 0, assoc = &cptr->assoc4; a < 2; a++, assoc = &cptr->assoc6) {
                    if (ip_isset(&assoc->ip_port.ip)) {
                        last_pinged = m->lastdump - assoc->last_pinged;

                        if (last_pinged > 999) {
                            last_pinged = 999;
                        }

                        char ip_str[IP_NTOA_LEN];
                        char id_str[IDSTRING_LEN];
                        LOGGER_TRACE(m->log, "F[%2u] => C[%2u] %s:%u [%3u] %s",
                                     friend_idx, client, ip_ntoa(&assoc->ip_port.ip, ip_str, sizeof(ip_str)),
                                     net_ntohs(assoc->ip_port.port), last_pinged,
                                     id_to_string(cptr->public_key, id_str, sizeof(id_str)));
                    }
                }
            }
        }
    }
}

/* new messenger format for load/save, more robust and forward compatible */

#define MESSENGER_STATE_COOKIE_GLOBAL 0x15ed1b1f

#define MESSENGER_STATE_COOKIE_TYPE      0x01ce
#define MESSENGER_STATE_TYPE_NOSPAMKEYS    1
#define MESSENGER_STATE_TYPE_DHT           2
#define MESSENGER_STATE_TYPE_FRIENDS       3
#define MESSENGER_STATE_TYPE_NAME          4
#define MESSENGER_STATE_TYPE_STATUSMESSAGE 5
#define MESSENGER_STATE_TYPE_STATUS        6
#define MESSENGER_STATE_TYPE_TCP_RELAY     10
#define MESSENGER_STATE_TYPE_PATH_NODE     11
#define MESSENGER_STATE_TYPE_END           255

#define SAVED_FRIEND_REQUEST_SIZE 1024
#define NUM_SAVED_PATH_NODES 8

struct SAVED_FRIEND {
    uint8_t status;
    uint8_t real_pk[CRYPTO_PUBLIC_KEY_SIZE];
    uint8_t info[SAVED_FRIEND_REQUEST_SIZE]; // the data that is sent during the friend requests we do.
    uint16_t info_size; // Length of the info.
    uint8_t name[MAX_NAME_LENGTH];
    uint16_t name_length;
    uint8_t statusmessage[MAX_STATUSMESSAGE_LENGTH];
    uint16_t statusmessage_length;
    uint8_t userstatus;
    uint32_t friendrequest_nospam;
    uint64_t last_seen_time;
};

static uint32_t friend_size(void)
{
    uint32_t data = 0;
    const struct SAVED_FRIEND *const temp = nullptr;

#define VALUE_MEMBER(NAME) data += sizeof(temp->NAME)
#define ARRAY_MEMBER(NAME) data += sizeof(temp->NAME)

    // Exactly the same in friend_load, friend_save, and friend_size
    VALUE_MEMBER(status);
    ARRAY_MEMBER(real_pk);
    ARRAY_MEMBER(info);
    data++; // padding
    VALUE_MEMBER(info_size);
    ARRAY_MEMBER(name);
    VALUE_MEMBER(name_length);
    ARRAY_MEMBER(statusmessage);
    data++; // padding
    VALUE_MEMBER(statusmessage_length);
    VALUE_MEMBER(userstatus);
    data += 3; // padding
    VALUE_MEMBER(friendrequest_nospam);
    VALUE_MEMBER(last_seen_time);

#undef VALUE_MEMBER
#undef ARRAY_MEMBER

    return data;
}

static uint32_t saved_friendslist_size(const Messenger *m)
{
    return count_friendlist(m) * friend_size();
}

static uint8_t *friend_save(const struct SAVED_FRIEND *temp, uint8_t *data)
{
#define VALUE_MEMBER(NAME)                            \
    memcpy(data, &temp->NAME, sizeof(temp->NAME));  \
    data += sizeof(temp->NAME)

#define ARRAY_MEMBER(NAME)                            \
    memcpy(data, temp->NAME, sizeof(temp->NAME));   \
    data += sizeof(temp->NAME)

    // Exactly the same in friend_load, friend_save, and friend_size
    VALUE_MEMBER(status);
    ARRAY_MEMBER(real_pk);
    ARRAY_MEMBER(info);
    data++; // padding
    VALUE_MEMBER(info_size);
    ARRAY_MEMBER(name);
    VALUE_MEMBER(name_length);
    ARRAY_MEMBER(statusmessage);
    data++; // padding
    VALUE_MEMBER(statusmessage_length);
    VALUE_MEMBER(userstatus);
    data += 3; // padding
    VALUE_MEMBER(friendrequest_nospam);
    VALUE_MEMBER(last_seen_time);

#undef VALUE_MEMBER
#undef ARRAY_MEMBER

    return data;
}

static uint32_t friends_list_save(const Messenger *m, uint8_t *data)
{
    uint32_t i;
    uint32_t num = 0;
    uint8_t *cur_data = data;

    for (i = 0; i < m->numfriends; i++) {
        if (m->friendlist[i].status > 0) {
            struct SAVED_FRIEND temp = { 0 };
            temp.status = m->friendlist[i].status;
            memcpy(temp.real_pk, m->friendlist[i].real_pk, CRYPTO_PUBLIC_KEY_SIZE);

            if (temp.status < 3) {
                const size_t friendrequest_length =
                    MIN(m->friendlist[i].info_size,
                        MIN(SAVED_FRIEND_REQUEST_SIZE, MAX_FRIEND_REQUEST_DATA_SIZE));
                memcpy(temp.info, m->friendlist[i].info, friendrequest_length);

                temp.info_size = net_htons(m->friendlist[i].info_size);
                temp.friendrequest_nospam = m->friendlist[i].friendrequest_nospam;
            } else {
                memcpy(temp.name, m->friendlist[i].name, m->friendlist[i].name_length);
                temp.name_length = net_htons(m->friendlist[i].name_length);
                memcpy(temp.statusmessage, m->friendlist[i].statusmessage, m->friendlist[i].statusmessage_length);
                temp.statusmessage_length = net_htons(m->friendlist[i].statusmessage_length);
                temp.userstatus = m->friendlist[i].userstatus;

                uint8_t last_seen_time[sizeof(uint64_t)];
                memcpy(last_seen_time, &m->friendlist[i].last_seen_time, sizeof(uint64_t));
                host_to_net(last_seen_time, sizeof(uint64_t));
                memcpy(&temp.last_seen_time, last_seen_time, sizeof(uint64_t));
            }

            uint8_t *next_data = friend_save(&temp, cur_data);
            assert(next_data - cur_data == friend_size());
#ifdef __LP64__
            assert(memcmp(cur_data, &temp, friend_size()) == 0);
#endif
            cur_data = next_data;
            num++;
        }
    }

    assert(cur_data - data == num * friend_size());
    return cur_data - data;
}

static const uint8_t *friend_load(struct SAVED_FRIEND *temp, const uint8_t *data)
{
#define VALUE_MEMBER(NAME)                            \
    memcpy(&temp->NAME, data, sizeof(temp->NAME));  \
    data += sizeof(temp->NAME)

#define ARRAY_MEMBER(NAME)                            \
    memcpy(temp->NAME, data, sizeof(temp->NAME));   \
    data += sizeof(temp->NAME)

    // Exactly the same in friend_load, friend_save, and friend_size
    VALUE_MEMBER(status);
    ARRAY_MEMBER(real_pk);
    ARRAY_MEMBER(info);
    data++; // padding
    VALUE_MEMBER(info_size);
    ARRAY_MEMBER(name);
    VALUE_MEMBER(name_length);
    ARRAY_MEMBER(statusmessage);
    data++; // padding
    VALUE_MEMBER(statusmessage_length);
    VALUE_MEMBER(userstatus);
    data += 3; // padding
    VALUE_MEMBER(friendrequest_nospam);
    VALUE_MEMBER(last_seen_time);

#undef VALUE_MEMBER
#undef ARRAY_MEMBER

    return data;
}

static int friends_list_load(Messenger *m, const uint8_t *data, uint32_t length)
{
    if (length % friend_size() != 0) {
        return -1;
    }

    uint32_t num = length / friend_size();
    uint32_t i;
    const uint8_t *cur_data = data;

    for (i = 0; i < num; ++i) {
        struct SAVED_FRIEND temp = { 0 };
        const uint8_t *next_data = friend_load(&temp, cur_data);
        assert(next_data - cur_data == friend_size());
#ifdef __LP64__
        assert(memcmp(&temp, cur_data, friend_size()) == 0);
#endif
        cur_data = next_data;

        if (temp.status >= 3) {
            int fnum = m_addfriend_norequest(m, temp.real_pk);

            if (fnum < 0) {
                continue;
            }

            setfriendname(m, fnum, temp.name, net_ntohs(temp.name_length));
            set_friend_statusmessage(m, fnum, temp.statusmessage, net_ntohs(temp.statusmessage_length));
            set_friend_userstatus(m, fnum, temp.userstatus);
            uint8_t last_seen_time[sizeof(uint64_t)];
            memcpy(last_seen_time, &temp.last_seen_time, sizeof(uint64_t));
            net_to_host(last_seen_time, sizeof(uint64_t));
            memcpy(&m->friendlist[fnum].last_seen_time, last_seen_time, sizeof(uint64_t));
        } else if (temp.status != 0) {
            /* TODO(irungentoo): This is not a good way to do this. */
            uint8_t address[FRIEND_ADDRESS_SIZE];
            id_copy(address, temp.real_pk);
            memcpy(address + CRYPTO_PUBLIC_KEY_SIZE, &temp.friendrequest_nospam, sizeof(uint32_t));
            uint16_t checksum = address_checksum(address, FRIEND_ADDRESS_SIZE - sizeof(checksum));
            memcpy(address + CRYPTO_PUBLIC_KEY_SIZE + sizeof(uint32_t), &checksum, sizeof(checksum));
            m_addfriend(m, address, temp.info, net_ntohs(temp.info_size));
        }
    }

    return num;
}

/*  return size of the messenger data (for saving) */
uint32_t messenger_size(const Messenger *m)
{
    uint32_t size32 = sizeof(uint32_t), sizesubhead = size32 * 2;
    return   size32 * 2                                      // global cookie
             + sizesubhead + sizeof(uint32_t) + CRYPTO_PUBLIC_KEY_SIZE + CRYPTO_SECRET_KEY_SIZE
             + sizesubhead + DHT_size(m->dht)                  // DHT
             + sizesubhead + saved_friendslist_size(m)         // Friendlist itself.
             + sizesubhead + m->name_length                    // Own nickname.
             + sizesubhead + m->statusmessage_length           // status message
             + sizesubhead + 1                                 // status
             + sizesubhead + NUM_SAVED_TCP_RELAYS * packed_node_size(TCP_INET6) //TCP relays
             + sizesubhead + NUM_SAVED_PATH_NODES * packed_node_size(TCP_INET6) //saved path nodes
             + sizesubhead;
}

static uint8_t *messenger_save_subheader(uint8_t *data, uint32_t len, uint16_t type)
{
    host_to_lendian32(data, len);
    data += sizeof(uint32_t);
    host_to_lendian32(data, (host_tolendian16(MESSENGER_STATE_COOKIE_TYPE) << 16) | host_tolendian16(type));
    data += sizeof(uint32_t);
    return data;
}

/* Save the messenger in data of size Messenger_size(). */
void messenger_save(const Messenger *m, uint8_t *data)
{
    memset(data, 0, messenger_size(m));

    uint32_t len;
    uint16_t type;
    uint32_t size32 = sizeof(uint32_t);

    memset(data, 0, size32);
    data += size32;
    host_to_lendian32(data, MESSENGER_STATE_COOKIE_GLOBAL);
    data += size32;

    assert(sizeof(get_nospam(m->fr)) == sizeof(uint32_t));
    len = size32 + CRYPTO_PUBLIC_KEY_SIZE + CRYPTO_SECRET_KEY_SIZE;
    type = MESSENGER_STATE_TYPE_NOSPAMKEYS;
    data = messenger_save_subheader(data, len, type);
    *(uint32_t *)data = get_nospam(m->fr);
    save_keys(m->net_crypto, data + size32);
    data += len;

    len = saved_friendslist_size(m);
    type = MESSENGER_STATE_TYPE_FRIENDS;
    data = messenger_save_subheader(data, len, type);
    friends_list_save(m, data);
    data += len;

    len = m->name_length;
    type = MESSENGER_STATE_TYPE_NAME;
    data = messenger_save_subheader(data, len, type);
    memcpy(data, m->name, len);
    data += len;

    len = m->statusmessage_length;
    type = MESSENGER_STATE_TYPE_STATUSMESSAGE;
    data = messenger_save_subheader(data, len, type);
    memcpy(data, m->statusmessage, len);
    data += len;

    len = 1;
    type = MESSENGER_STATE_TYPE_STATUS;
    data = messenger_save_subheader(data, len, type);
    *data = m->userstatus;
    data += len;

    len = DHT_size(m->dht);
    type = MESSENGER_STATE_TYPE_DHT;
    data = messenger_save_subheader(data, len, type);
    DHT_save(m->dht, data);
    data += len;

    Node_format relays[NUM_SAVED_TCP_RELAYS];
    type = MESSENGER_STATE_TYPE_TCP_RELAY;
    uint8_t *temp_data = data;
    data = messenger_save_subheader(temp_data, 0, type);
    unsigned int num = copy_connected_tcp_relays(m->net_crypto, relays, NUM_SAVED_TCP_RELAYS);
    int l = pack_nodes(data, NUM_SAVED_TCP_RELAYS * packed_node_size(TCP_INET6), relays, num);

    if (l > 0) {
        len = l;
        data = messenger_save_subheader(temp_data, len, type);
        data += len;
    }

    Node_format nodes[NUM_SAVED_PATH_NODES];
    type = MESSENGER_STATE_TYPE_PATH_NODE;
    temp_data = data;
    data = messenger_save_subheader(data, 0, type);
    memset(nodes, 0, sizeof(nodes));
    num = onion_backup_nodes(m->onion_c, nodes, NUM_SAVED_PATH_NODES);
    l = pack_nodes(data, NUM_SAVED_PATH_NODES * packed_node_size(TCP_INET6), nodes, num);

    if (l > 0) {
        len = l;
        data = messenger_save_subheader(temp_data, len, type);
        data += len;
    }

    messenger_save_subheader(data, 0, MESSENGER_STATE_TYPE_END);
}

static int messenger_load_state_callback(void *outer, const uint8_t *data, uint32_t length, uint16_t type)
{
    Messenger *m = (Messenger *)outer;

    switch (type) {
        case MESSENGER_STATE_TYPE_NOSPAMKEYS:
            if (length == CRYPTO_PUBLIC_KEY_SIZE + CRYPTO_SECRET_KEY_SIZE + sizeof(uint32_t)) {
                set_nospam(m->fr, *(const uint32_t *)data);
                load_secret_key(m->net_crypto, (&data[sizeof(uint32_t)]) + CRYPTO_PUBLIC_KEY_SIZE);

                if (public_key_cmp((&data[sizeof(uint32_t)]), nc_get_self_public_key(m->net_crypto)) != 0) {
                    return -1;
                }
            } else {
                return -1;    /* critical */
            }

            break;

        case MESSENGER_STATE_TYPE_DHT:
            DHT_load(m->dht, data, length);
            break;

        case MESSENGER_STATE_TYPE_FRIENDS:
            friends_list_load(m, data, length);
            break;

        case MESSENGER_STATE_TYPE_NAME:
            if ((length > 0) && (length <= MAX_NAME_LENGTH)) {
                setname(m, data, length);
            }

            break;

        case MESSENGER_STATE_TYPE_STATUSMESSAGE:
            if ((length > 0) && (length <= MAX_STATUSMESSAGE_LENGTH)) {
                m_set_statusmessage(m, data, length);
            }

            break;

        case MESSENGER_STATE_TYPE_STATUS:
            if (length == 1) {
                m_set_userstatus(m, *data);
            }

            break;

        case MESSENGER_STATE_TYPE_TCP_RELAY: {
            if (length == 0) {
                break;
            }

            unpack_nodes(m->loaded_relays, NUM_SAVED_TCP_RELAYS, nullptr, data, length, 1);
            m->has_added_relays = 0;

            break;
        }

        case MESSENGER_STATE_TYPE_PATH_NODE: {
            Node_format nodes[NUM_SAVED_PATH_NODES];

            if (length == 0) {
                break;
            }

            int i, num = unpack_nodes(nodes, NUM_SAVED_PATH_NODES, nullptr, data, length, 0);

            for (i = 0; i < num; ++i) {
                onion_add_bs_path_node(m->onion_c, nodes[i].ip_port, nodes[i].public_key);
            }

            break;
        }

        case MESSENGER_STATE_TYPE_END: {
            if (length != 0) {
                return -1;
            }

            return -2;
        }

        default:
            LOGGER_ERROR(m->log, "Load state: contains unrecognized part (len %u, type %u)\n",
                         length, type);
            break;
    }

    return 0;
}

/* Load the messenger from data of size length. */
int messenger_load(Messenger *m, const uint8_t *data, uint32_t length)
{
    uint32_t data32[2];
    uint32_t cookie_len = sizeof(data32);

    if (length < cookie_len) {
        return -1;
    }

    memcpy(data32, data, sizeof(uint32_t));
    lendian_to_host32(data32 + 1, data + sizeof(uint32_t));

    if (!data32[0] && (data32[1] == MESSENGER_STATE_COOKIE_GLOBAL)) {
        return load_state(messenger_load_state_callback, m->log, m, data + cookie_len,
                          length - cookie_len, MESSENGER_STATE_COOKIE_TYPE);
    }

    return -1;
}

/* Return the number of friends in the instance m.
 * You should use this to determine how much memory to allocate
 * for copy_friendlist. */
uint32_t count_friendlist(const Messenger *m)
{
    uint32_t ret = 0;
    uint32_t i;

    for (i = 0; i < m->numfriends; i++) {
        if (m->friendlist[i].status > 0) {
            ret++;
        }
    }

    return ret;
}

/* Copy a list of valid friend IDs into the array out_list.
 * If out_list is NULL, returns 0.
 * Otherwise, returns the number of elements copied.
 * If the array was too small, the contents
 * of out_list will be truncated to list_size. */
uint32_t copy_friendlist(Messenger const *m, uint32_t *out_list, uint32_t list_size)
{
    if (!out_list) {
        return 0;
    }

    if (m->numfriends == 0) {
        return 0;
    }

    uint32_t i;
    uint32_t ret = 0;

    for (i = 0; i < m->numfriends; i++) {
        if (ret >= list_size) {
            break; /* Abandon ship */
        }

        if (m->friendlist[i].status > 0) {
            out_list[ret] = i;
            ret++;
        }
    }

    return ret;
}
