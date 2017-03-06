/*
 * Functions for the core networking.
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

#define _DARWIN_C_SOURCE
#define _XOPEN_SOURCE 600

#if defined(_WIN32) && _WIN32_WINNT >= _WIN32_WINNT_WINXP
#define _WIN32_WINNT  0x501
#endif

#include "network.h"

#include "logger.h"
#include "util.h"

#include <assert.h>
#ifdef __APPLE__
#include <mach/clock.h>
#include <mach/mach.h>
#endif

#ifndef IPV6_ADD_MEMBERSHIP
#ifdef  IPV6_JOIN_GROUP
#define IPV6_ADD_MEMBERSHIP IPV6_JOIN_GROUP
#define IPV6_DROP_MEMBERSHIP IPV6_LEAVE_GROUP
#endif
#endif

#if !(defined(_WIN32) || defined(__WIN32__) || defined(WIN32))

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/socket.h>

#else

#ifndef IPV6_V6ONLY
#define IPV6_V6ONLY 27
#endif

#ifndef EWOULDBLOCK
#define EWOULDBLOCK WSAEWOULDBLOCK
#endif

static const char *inet_ntop(sa_family_t family, const void *addr, char *buf, size_t bufsize)
{
    if (family == AF_INET) {
        struct sockaddr_in saddr;
        memset(&saddr, 0, sizeof(saddr));

        saddr.sin_family = AF_INET;
        saddr.sin_addr = *(const struct in_addr *)addr;

        DWORD len = bufsize;

        if (WSAAddressToString((LPSOCKADDR)&saddr, sizeof(saddr), NULL, buf, &len)) {
            return NULL;
        }

        return buf;
    } else if (family == AF_INET6) {
        struct sockaddr_in6 saddr;
        memset(&saddr, 0, sizeof(saddr));

        saddr.sin6_family = AF_INET6;
        saddr.sin6_addr = *(const struct in6_addr *)addr;

        DWORD len = bufsize;

        if (WSAAddressToString((LPSOCKADDR)&saddr, sizeof(saddr), NULL, buf, &len)) {
            return NULL;
        }

        return buf;
    }

    return NULL;
}

static int inet_pton(sa_family_t family, const char *addrString, void *addrbuf)
{
    if (family == AF_INET) {
        struct sockaddr_in saddr;
        memset(&saddr, 0, sizeof(saddr));

        INT len = sizeof(saddr);

        if (WSAStringToAddress((LPTSTR)addrString, AF_INET, NULL, (LPSOCKADDR)&saddr, &len)) {
            return 0;
        }

        *(struct in_addr *)addrbuf = saddr.sin_addr;

        return 1;
    } else if (family == AF_INET6) {
        struct sockaddr_in6 saddr;
        memset(&saddr, 0, sizeof(saddr));

        INT len = sizeof(saddr);

        if (WSAStringToAddress((LPTSTR)addrString, AF_INET6, NULL, (LPSOCKADDR)&saddr, &len)) {
            return 0;
        }

        *(struct in6_addr *)addrbuf = saddr.sin6_addr;

        return 1;
    }

    return 0;
}

#endif

/* Check if socket is valid.
 *
 * return 1 if valid
 * return 0 if not valid
 */
int sock_valid(Socket sock)
{
#if defined(_WIN32) || defined(__WIN32__) || defined (WIN32)

    if (sock == INVALID_SOCKET) {
#else

    if (sock < 0) {
#endif
        return 0;
    }

    return 1;
}

/* Close the socket.
 */
void kill_sock(Socket sock)
{
#if defined(_WIN32) || defined(__WIN32__) || defined (WIN32)
    closesocket(sock);
#else
    close(sock);
#endif
}

/* Set socket as nonblocking
 *
 * return 1 on success
 * return 0 on failure
 */
int set_socket_nonblock(Socket sock)
{
#if defined(_WIN32) || defined(__WIN32__) || defined (WIN32)
    u_long mode = 1;
    return (ioctlsocket(sock, FIONBIO, &mode) == 0);
#else
    return (fcntl(sock, F_SETFL, O_NONBLOCK, 1) == 0);
#endif
}

/* Set socket to not emit SIGPIPE
 *
 * return 1 on success
 * return 0 on failure
 */
int set_socket_nosigpipe(Socket sock)
{
#if defined(__MACH__)
    int set = 1;
    return (setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, (const char *)&set, sizeof(int)) == 0);
#else
    return 1;
#endif
}

/* Enable SO_REUSEADDR on socket.
 *
 * return 1 on success
 * return 0 on failure
 */
int set_socket_reuseaddr(Socket sock)
{
    int set = 1;
    return (setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, (const char *)&set, sizeof(set)) == 0);
}

/* Set socket to dual (IPv4 + IPv6 socket)
 *
 * return 1 on success
 * return 0 on failure
 */
int set_socket_dualstack(Socket sock)
{
    int ipv6only = 0;
    socklen_t optsize = sizeof(ipv6only);
    int res = getsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, (char *)&ipv6only, &optsize);

    if ((res == 0) && (ipv6only == 0)) {
        return 1;
    }

    ipv6only = 0;
    return (setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, (const char *)&ipv6only, sizeof(ipv6only)) == 0);
}


/*  return current UNIX time in microseconds (us). */
static uint64_t current_time_actual(void)
{
    uint64_t time;
#if defined(_WIN32) || defined(__WIN32__) || defined (WIN32)
    /* This probably works fine */
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    time = ft.dwHighDateTime;
    time <<= 32;
    time |= ft.dwLowDateTime;
    time -= 116444736000000000ULL;
    return time / 10;
#else
    struct timeval a;
    gettimeofday(&a, NULL);
    time = 1000000ULL * a.tv_sec + a.tv_usec;
    return time;
#endif
}


#if defined(_WIN32) || defined(__WIN32__) || defined (WIN32)
static uint64_t last_monotime;
static uint64_t add_monotime;
#endif

/* return current monotonic time in milliseconds (ms). */
uint64_t current_time_monotonic(void)
{
    uint64_t time;
#if defined(_WIN32) || defined(__WIN32__) || defined (WIN32)
    uint64_t old_add_monotime = add_monotime;
    time = (uint64_t)GetTickCount() + add_monotime;

    /* Check if time has decreased because of 32 bit wrap from GetTickCount(), while avoiding false positives from race
     * conditions when multiple threads call this function at once */
    if (time + 0x10000 < last_monotime) {
        uint32_t add = ~0;
        /* use old_add_monotime rather than simply incrementing add_monotime, to handle the case that many threads
         * simultaneously detect an overflow */
        add_monotime = old_add_monotime + add;
        time += add;
    }

    last_monotime = time;
#else
    struct timespec monotime;
#if defined(__linux__) && defined(CLOCK_MONOTONIC_RAW)
    clock_gettime(CLOCK_MONOTONIC_RAW, &monotime);
#elif defined(__APPLE__)
    clock_serv_t muhclock;
    mach_timespec_t machtime;

    host_get_clock_service(mach_host_self(), SYSTEM_CLOCK, &muhclock);
    clock_get_time(muhclock, &machtime);
    mach_port_deallocate(mach_task_self(), muhclock);

    monotime.tv_sec = machtime.tv_sec;
    monotime.tv_nsec = machtime.tv_nsec;
#else
    clock_gettime(CLOCK_MONOTONIC, &monotime);
#endif
    time = 1000ULL * monotime.tv_sec + (monotime.tv_nsec / 1000000ULL);
#endif
    return time;
}

static uint32_t data_0(uint16_t buflen, const uint8_t *buffer)
{
    return buflen > 4 ? ntohl(*(const uint32_t *)&buffer[1]) : 0;
}
static uint32_t data_1(uint16_t buflen, const uint8_t *buffer)
{
    return buflen > 7 ? ntohl(*(const uint32_t *)&buffer[5]) : 0;
}

static void loglogdata(Logger *log, const char *message, const uint8_t *buffer,
                       uint16_t buflen, IP_Port ip_port, int res)
{
    char ip_str[IP_NTOA_LEN];

    if (res < 0) { /* Windows doesn't necessarily know %zu */
        LOGGER_TRACE(log, "[%2u] %s %3hu%c %s:%hu (%u: %s) | %04x%04x",
                     buffer[0], message, (buflen < 999 ? (uint16_t)buflen : 999), 'E',
                     ip_ntoa(&ip_port.ip, ip_str, sizeof(ip_str)), ntohs(ip_port.port), errno,
                     strerror(errno), data_0(buflen, buffer), data_1(buflen, buffer));
    } else if ((res > 0) && ((size_t)res <= buflen)) {
        LOGGER_TRACE(log, "[%2u] %s %3zu%c %s:%hu (%u: %s) | %04x%04x",
                     buffer[0], message, (res < 999 ? (size_t)res : 999), ((size_t)res < buflen ? '<' : '='),
                     ip_ntoa(&ip_port.ip, ip_str, sizeof(ip_str)), ntohs(ip_port.port), 0, "OK",
                     data_0(buflen, buffer), data_1(buflen, buffer));
    } else { /* empty or overwrite */
        LOGGER_TRACE(log, "[%2u] %s %zu%c%zu %s:%hu (%u: %s) | %04x%04x",
                     buffer[0], message, (size_t)res, (!res ? '!' : '>'), buflen,
                     ip_ntoa(&ip_port.ip, ip_str, sizeof(ip_str)), ntohs(ip_port.port), 0, "OK",
                     data_0(buflen, buffer), data_1(buflen, buffer));
    }
}

void get_ip4(IP4 *result, const struct in_addr *addr)
{
    result->uint32 = addr->s_addr;
}

void get_ip6(IP6 *result, const struct in6_addr *addr)
{
    assert(sizeof(result->uint8) == sizeof(addr->s6_addr));
    memcpy(result->uint8, addr->s6_addr, sizeof(result->uint8));
}


void fill_addr4(IP4 ip, struct in_addr *addr)
{
    addr->s_addr = ip.uint32;
}

void fill_addr6(IP6 ip, struct in6_addr *addr)
{
    assert(sizeof(ip.uint8) == sizeof(addr->s6_addr));
    memcpy(addr->s6_addr, ip.uint8, sizeof(ip.uint8));
}

/* Basic network functions:
 * Function to send packet(data) of length length to ip_port.
 */
int sendpacket(Networking_Core *net, IP_Port ip_port, const uint8_t *data, uint16_t length)
{
    if (net->family == 0) { /* Socket not initialized */
        return -1;
    }

    /* socket AF_INET, but target IP NOT: can't send */
    if ((net->family == AF_INET) && (ip_port.ip.family != AF_INET)) {
        return -1;
    }

    struct sockaddr_storage addr;

    size_t addrsize = 0;

    if (ip_port.ip.family == AF_INET) {
        if (net->family == AF_INET6) {
            /* must convert to IPV4-in-IPV6 address */
            struct sockaddr_in6 *addr6 = (struct sockaddr_in6 *)&addr;

            addrsize = sizeof(struct sockaddr_in6);
            addr6->sin6_family = AF_INET6;
            addr6->sin6_port = ip_port.port;

            /* there should be a macro for this in a standards compliant
             * environment, not found */
            IP6 ip6;

            ip6.uint32[0] = 0;
            ip6.uint32[1] = 0;
            ip6.uint32[2] = htonl(0xFFFF);
            ip6.uint32[3] = ip_port.ip.ip4.uint32;
            fill_addr6(ip6, &addr6->sin6_addr);

            addr6->sin6_flowinfo = 0;
            addr6->sin6_scope_id = 0;
        } else {
            struct sockaddr_in *addr4 = (struct sockaddr_in *)&addr;

            addrsize = sizeof(struct sockaddr_in);
            addr4->sin_family = AF_INET;
            fill_addr4(ip_port.ip.ip4, &addr4->sin_addr);
            addr4->sin_port = ip_port.port;
        }
    } else if (ip_port.ip.family == AF_INET6) {
        struct sockaddr_in6 *addr6 = (struct sockaddr_in6 *)&addr;

        addrsize = sizeof(struct sockaddr_in6);
        addr6->sin6_family = AF_INET6;
        addr6->sin6_port = ip_port.port;
        fill_addr6(ip_port.ip.ip6, &addr6->sin6_addr);

        addr6->sin6_flowinfo = 0;
        addr6->sin6_scope_id = 0;
    } else {
        /* unknown address type*/
        return -1;
    }

    int res = sendto(net->sock, (const char *) data, length, 0, (struct sockaddr *)&addr, addrsize);

    loglogdata(net->log, "O=>", data, length, ip_port, res);

    return res;
}

/* Function to receive data
 *  ip and port of sender is put into ip_port.
 *  Packet data is put into data.
 *  Packet length is put into length.
 */
static int receivepacket(Logger *log, Socket sock, IP_Port *ip_port, uint8_t *data, uint32_t *length)
{
    memset(ip_port, 0, sizeof(IP_Port));
    struct sockaddr_storage addr;
#if defined(_WIN32) || defined(__WIN32__) || defined (WIN32)
    int addrlen = sizeof(addr);
#else
    socklen_t addrlen = sizeof(addr);
#endif
    *length = 0;
    int fail_or_len = recvfrom(sock, (char *) data, MAX_UDP_PACKET_SIZE, 0, (struct sockaddr *)&addr, &addrlen);

    if (fail_or_len < 0) {

        if (fail_or_len < 0 && errno != EWOULDBLOCK) {
            LOGGER_ERROR(log, "Unexpected error reading from socket: %u, %s\n", errno, strerror(errno));
        }

        return -1; /* Nothing received. */
    }

    *length = (uint32_t)fail_or_len;

    if (addr.ss_family == AF_INET) {
        struct sockaddr_in *addr_in = (struct sockaddr_in *)&addr;

        ip_port->ip.family = addr_in->sin_family;
        get_ip4(&ip_port->ip.ip4, &addr_in->sin_addr);
        ip_port->port = addr_in->sin_port;
    } else if (addr.ss_family == AF_INET6) {
        struct sockaddr_in6 *addr_in6 = (struct sockaddr_in6 *)&addr;
        ip_port->ip.family = addr_in6->sin6_family;
        get_ip6(&ip_port->ip.ip6, &addr_in6->sin6_addr);
        ip_port->port = addr_in6->sin6_port;

        if (IPV6_IPV4_IN_V6(ip_port->ip.ip6)) {
            ip_port->ip.family = AF_INET;
            ip_port->ip.ip4.uint32 = ip_port->ip.ip6.uint32[3];
        }
    } else {
        return -1;
    }

    loglogdata(log, "=>O", data, MAX_UDP_PACKET_SIZE, *ip_port, *length);

    return 0;
}

void networking_registerhandler(Networking_Core *net, uint8_t byte, packet_handler_callback cb, void *object)
{
    net->packethandlers[byte].function = cb;
    net->packethandlers[byte].object = object;
}

void networking_poll(Networking_Core *net, void *userdata)
{
    if (net->family == 0) { /* Socket not initialized */
        return;
    }

    unix_time_update();

    IP_Port ip_port;
    uint8_t data[MAX_UDP_PACKET_SIZE];
    uint32_t length;

    while (receivepacket(net->log, net->sock, &ip_port, data, &length) != -1) {
        if (length < 1) {
            continue;
        }

        if (!(net->packethandlers[data[0]].function)) {
            LOGGER_WARNING(net->log, "[%02u] -- Packet has no handler", data[0]);
            continue;
        }

        net->packethandlers[data[0]].function(net->packethandlers[data[0]].object, ip_port, data, length, userdata);
    }
}

#ifndef VANILLA_NACL
/* Used for sodium_init() */
#include "sodium.h"
#endif

static uint8_t at_startup_ran = 0;
int networking_at_startup(void)
{
    if (at_startup_ran != 0) {
        return 0;
    }

#ifndef VANILLA_NACL

#ifdef USE_RANDOMBYTES_STIR
    randombytes_stir();
#else

    if (sodium_init() == -1) {
        return -1;
    }

#endif /*USE_RANDOMBYTES_STIR*/

#endif/*VANILLA_NACL*/

#if defined(_WIN32) || defined(__WIN32__) || defined (WIN32)
    WSADATA wsaData;

    if (WSAStartup(MAKEWORD(2, 2), &wsaData) != NO_ERROR) {
        return -1;
    }

#endif
    srand((uint32_t)current_time_actual());
    at_startup_ran = 1;
    return 0;
}

/* TODO(irungentoo): Put this somewhere */
#if 0
static void at_shutdown(void)
{
#if defined(_WIN32) || defined(__WIN32__) || defined (WIN32)
    WSACleanup();
#endif
}
#endif

/* Initialize networking.
 * Added for reverse compatibility with old new_networking calls.
 */
Networking_Core *new_networking(Logger *log, IP ip, uint16_t port)
{
    return new_networking_ex(log, ip, port, port + (TOX_PORTRANGE_TO - TOX_PORTRANGE_FROM), 0);
}

/* Initialize networking.
 * Bind to ip and port.
 * ip must be in network order EX: 127.0.0.1 = (7F000001).
 * port is in host byte order (this means don't worry about it).
 *
 *  return Networking_Core object if no problems
 *  return NULL if there are problems.
 *
 * If error is non NULL it is set to 0 if no issues, 1 if socket related error, 2 if other.
 */
Networking_Core *new_networking_ex(Logger *log, IP ip, uint16_t port_from, uint16_t port_to, unsigned int *error)
{
    /* If both from and to are 0, use default port range
     * If one is 0 and the other is non-0, use the non-0 value as only port
     * If from > to, swap
     */
    if (port_from == 0 && port_to == 0) {
        port_from = TOX_PORTRANGE_FROM;
        port_to = TOX_PORTRANGE_TO;
    } else if (port_from == 0 && port_to != 0) {
        port_from = port_to;
    } else if (port_from != 0 && port_to == 0) {
        port_to = port_from;
    } else if (port_from > port_to) {
        uint16_t temp = port_from;
        port_from = port_to;
        port_to = temp;
    }

    if (error) {
        *error = 2;
    }

    /* maybe check for invalid IPs like 224+.x.y.z? if there is any IP set ever */
    if (ip.family != AF_INET && ip.family != AF_INET6) {
        LOGGER_ERROR(log, "Invalid address family: %u\n", ip.family);
        return NULL;
    }

    if (networking_at_startup() != 0) {
        return NULL;
    }

    Networking_Core *temp = (Networking_Core *)calloc(1, sizeof(Networking_Core));

    if (temp == NULL) {
        return NULL;
    }

    temp->log = log;
    temp->family = ip.family;
    temp->port = 0;

    /* Initialize our socket. */
    /* add log message what we're creating */
    temp->sock = socket(temp->family, SOCK_DGRAM, IPPROTO_UDP);

    /* Check for socket error. */
    if (!sock_valid(temp->sock)) {
        LOGGER_ERROR(log, "Failed to get a socket?! %u, %s\n", errno, strerror(errno));
        free(temp);

        if (error) {
            *error = 1;
        }

        return NULL;
    }

    /* Functions to increase the size of the send and receive UDP buffers.
     */
    int n = 1024 * 1024 * 2;
    setsockopt(temp->sock, SOL_SOCKET, SO_RCVBUF, (const char *)&n, sizeof(n));
    setsockopt(temp->sock, SOL_SOCKET, SO_SNDBUF, (const char *)&n, sizeof(n));

    /* Enable broadcast on socket */
    int broadcast = 1;
    setsockopt(temp->sock, SOL_SOCKET, SO_BROADCAST, (const char *)&broadcast, sizeof(broadcast));

    /* iOS UDP sockets are weird and apparently can SIGPIPE */
    if (!set_socket_nosigpipe(temp->sock)) {
        kill_networking(temp);

        if (error) {
            *error = 1;
        }

        return NULL;
    }

    /* Set socket nonblocking. */
    if (!set_socket_nonblock(temp->sock)) {
        kill_networking(temp);

        if (error) {
            *error = 1;
        }

        return NULL;
    }

    /* Bind our socket to port PORT and the given IP address (usually 0.0.0.0 or ::) */
    uint16_t *portptr = NULL;
    struct sockaddr_storage addr;
    size_t addrsize;

    if (temp->family == AF_INET) {
        struct sockaddr_in *addr4 = (struct sockaddr_in *)&addr;

        addrsize = sizeof(struct sockaddr_in);
        addr4->sin_family = AF_INET;
        addr4->sin_port = 0;
        fill_addr4(ip.ip4, &addr4->sin_addr);

        portptr = &addr4->sin_port;
    } else if (temp->family == AF_INET6) {
        struct sockaddr_in6 *addr6 = (struct sockaddr_in6 *)&addr;

        addrsize = sizeof(struct sockaddr_in6);
        addr6->sin6_family = AF_INET6;
        addr6->sin6_port = 0;
        fill_addr6(ip.ip6, &addr6->sin6_addr);

        addr6->sin6_flowinfo = 0;
        addr6->sin6_scope_id = 0;

        portptr = &addr6->sin6_port;
    } else {
        free(temp);
        return NULL;
    }

    if (ip.family == AF_INET6) {
        int is_dualstack = set_socket_dualstack(temp->sock);
        LOGGER_DEBUG(log, "Dual-stack socket: %s",
                     is_dualstack ? "enabled" : "Failed to enable, won't be able to receive from/send to IPv4 addresses");
        /* multicast local nodes */
        struct ipv6_mreq mreq;
        memset(&mreq, 0, sizeof(mreq));
        mreq.ipv6mr_multiaddr.s6_addr[ 0] = 0xFF;
        mreq.ipv6mr_multiaddr.s6_addr[ 1] = 0x02;
        mreq.ipv6mr_multiaddr.s6_addr[15] = 0x01;
        mreq.ipv6mr_interface = 0;
        int res = setsockopt(temp->sock, IPPROTO_IPV6, IPV6_ADD_MEMBERSHIP, (const char *)&mreq, sizeof(mreq));

        LOGGER_DEBUG(log, res < 0 ? "Failed to activate local multicast membership. (%u, %s)" :
                     "Local multicast group FF02::1 joined successfully", errno, strerror(errno));
    }

    /* a hanging program or a different user might block the standard port;
     * as long as it isn't a parameter coming from the commandline,
     * try a few ports after it, to see if we can find a "free" one
     *
     * if we go on without binding, the first sendto() automatically binds to
     * a free port chosen by the system (i.e. anything from 1024 to 65535)
     *
     * returning NULL after bind fails has both advantages and disadvantages:
     * advantage:
     *   we can rely on getting the port in the range 33445..33450, which
     *   enables us to tell joe user to open their firewall to a small range
     *
     * disadvantage:
     *   some clients might not test return of tox_new(), blindly assuming that
     *   it worked ok (which it did previously without a successful bind)
     */
    uint16_t port_to_try = port_from;
    *portptr = htons(port_to_try);
    int tries;

    for (tries = port_from; tries <= port_to; tries++) {
        int res = bind(temp->sock, (struct sockaddr *)&addr, addrsize);

        if (!res) {
            temp->port = *portptr;

            char ip_str[IP_NTOA_LEN];
            LOGGER_DEBUG(log, "Bound successfully to %s:%u", ip_ntoa(&ip, ip_str, sizeof(ip_str)),
                         ntohs(temp->port));

            /* errno isn't reset on success, only set on failure, the failed
             * binds with parallel clients yield a -EPERM to the outside if
             * errno isn't cleared here */
            if (tries > 0) {
                errno = 0;
            }

            if (error) {
                *error = 0;
            }

            return temp;
        }

        port_to_try++;

        if (port_to_try > port_to) {
            port_to_try = port_from;
        }

        *portptr = htons(port_to_try);
    }

    char ip_str[IP_NTOA_LEN];
    LOGGER_ERROR(log, "Failed to bind socket: %u, %s IP: %s port_from: %u port_to: %u", errno, strerror(errno),
                 ip_ntoa(&ip, ip_str, sizeof(ip_str)), port_from, port_to);

    kill_networking(temp);

    if (error) {
        *error = 1;
    }

    return NULL;
}

/* Function to cleanup networking stuff. */
void kill_networking(Networking_Core *net)
{
    if (!net) {
        return;
    }

    if (net->family != 0) { /* Socket not initialized */
        kill_sock(net->sock);
    }

    free(net);
}


/* ip_equal
 *  compares two IPAny structures
 *  unset means unequal
 *
 * returns 0 when not equal or when uninitialized
 */
int ip_equal(const IP *a, const IP *b)
{
    if (!a || !b) {
        return 0;
    }

    /* same family */
    if (a->family == b->family) {
        if (a->family == AF_INET) {
            struct in_addr addr_a;
            struct in_addr addr_b;
            fill_addr4(a->ip4, &addr_a);
            fill_addr4(b->ip4, &addr_b);
            return addr_a.s_addr == addr_b.s_addr;
        }

        if (a->family == AF_INET6) {
            return a->ip6.uint64[0] == b->ip6.uint64[0] &&
                   a->ip6.uint64[1] == b->ip6.uint64[1];
        }

        return 0;
    }

    /* different family: check on the IPv6 one if it is the IPv4 one embedded */
    if ((a->family == AF_INET) && (b->family == AF_INET6)) {
        if (IPV6_IPV4_IN_V6(b->ip6)) {
            struct in_addr addr_a;
            fill_addr4(a->ip4, &addr_a);
            return addr_a.s_addr == b->ip6.uint32[3];
        }
    } else if ((a->family == AF_INET6)  && (b->family == AF_INET)) {
        if (IPV6_IPV4_IN_V6(a->ip6)) {
            struct in_addr addr_b;
            fill_addr4(b->ip4, &addr_b);
            return a->ip6.uint32[3] == addr_b.s_addr;
        }
    }

    return 0;
}

/* ipport_equal
 *  compares two IPAny_Port structures
 *  unset means unequal
 *
 * returns 0 when not equal or when uninitialized
 */
int ipport_equal(const IP_Port *a, const IP_Port *b)
{
    if (!a || !b) {
        return 0;
    }

    if (!a->port || (a->port != b->port)) {
        return 0;
    }

    return ip_equal(&a->ip, &b->ip);
}

/* nulls out ip */
void ip_reset(IP *ip)
{
    if (!ip) {
        return;
    }

    memset(ip, 0, sizeof(IP));
}

/* nulls out ip, sets family according to flag */
void ip_init(IP *ip, uint8_t ipv6enabled)
{
    if (!ip) {
        return;
    }

    memset(ip, 0, sizeof(IP));
    ip->family = ipv6enabled ? AF_INET6 : AF_INET;
}

/* checks if ip is valid */
int ip_isset(const IP *ip)
{
    if (!ip) {
        return 0;
    }

    return (ip->family != 0);
}

/* checks if ip is valid */
int ipport_isset(const IP_Port *ipport)
{
    if (!ipport) {
        return 0;
    }

    if (!ipport->port) {
        return 0;
    }

    return ip_isset(&ipport->ip);
}

/* copies an ip structure (careful about direction!) */
void ip_copy(IP *target, const IP *source)
{
    if (!source || !target) {
        return;
    }

    memcpy(target, source, sizeof(IP));
}

/* copies an ip_port structure (careful about direction!) */
void ipport_copy(IP_Port *target, const IP_Port *source)
{
    if (!source || !target) {
        return;
    }

    memcpy(target, source, sizeof(IP_Port));
}

/* ip_ntoa
 *   converts ip into a string
 *   ip_str must be of length at least IP_NTOA_LEN
 *
 *   IPv6 addresses are enclosed into square brackets, i.e. "[IPv6]"
 *   writes error message into the buffer on error
 *
 *   returns ip_str
 */
const char *ip_ntoa(const IP *ip, char *ip_str, size_t length)
{
    if (length < IP_NTOA_LEN) {
        snprintf(ip_str, length, "Bad buf length");
        return ip_str;
    }

    if (ip) {
        if (ip->family == AF_INET) {
            /* returns standard quad-dotted notation */
            const struct in_addr *addr = (const struct in_addr *)&ip->ip4;

            ip_str[0] = 0;
            inet_ntop(ip->family, addr, ip_str, length);
        } else if (ip->family == AF_INET6) {
            /* returns hex-groups enclosed into square brackets */
            const struct in6_addr *addr = (const struct in6_addr *)&ip->ip6;

            ip_str[0] = '[';
            inet_ntop(ip->family, addr, &ip_str[1], length - 3);
            size_t len = strlen(ip_str);
            ip_str[len] = ']';
            ip_str[len + 1] = 0;
        } else {
            snprintf(ip_str, length, "(IP invalid, family %u)", ip->family);
        }
    } else {
        snprintf(ip_str, length, "(IP invalid: NULL)");
    }

    /* brute force protection against lacking termination */
    ip_str[length - 1] = 0;
    return ip_str;
}

/*
 * ip_parse_addr
 *  parses IP structure into an address string
 *
 * input
 *  ip: ip of AF_INET or AF_INET6 families
 *  length: length of the address buffer
 *          Must be at least INET_ADDRSTRLEN for AF_INET
 *          and INET6_ADDRSTRLEN for AF_INET6
 *
 * output
 *  address: dotted notation (IPv4: quad, IPv6: 16) or colon notation (IPv6)
 *
 * returns 1 on success, 0 on failure
 */
int ip_parse_addr(const IP *ip, char *address, size_t length)
{
    if (!address || !ip) {
        return 0;
    }

    if (ip->family == AF_INET) {
        const struct in_addr *addr = (const struct in_addr *)&ip->ip4;
        return inet_ntop(ip->family, addr, address, length) != NULL;
    }

    if (ip->family == AF_INET6) {
        const struct in6_addr *addr = (const struct in6_addr *)&ip->ip6;
        return inet_ntop(ip->family, addr, address, length) != NULL;
    }

    return 0;
}

/*
 * addr_parse_ip
 *  directly parses the input into an IP structure
 *  tries IPv4 first, then IPv6
 *
 * input
 *  address: dotted notation (IPv4: quad, IPv6: 16) or colon notation (IPv6)
 *
 * output
 *  IP: family and the value is set on success
 *
 * returns 1 on success, 0 on failure
 */
int addr_parse_ip(const char *address, IP *to)
{
    if (!address || !to) {
        return 0;
    }

    struct in_addr addr4;

    if (1 == inet_pton(AF_INET, address, &addr4)) {
        to->family = AF_INET;
        get_ip4(&to->ip4, &addr4);
        return 1;
    }

    struct in6_addr addr6;

    if (1 == inet_pton(AF_INET6, address, &addr6)) {
        to->family = AF_INET6;
        get_ip6(&to->ip6, &addr6);
        return 1;
    }

    return 0;
}

/*
 * addr_resolve():
 *  uses getaddrinfo to resolve an address into an IP address
 *  uses the first IPv4/IPv6 addresses returned by getaddrinfo
 *
 * input
 *  address: a hostname (or something parseable to an IP address)
 *  to: to.family MUST be initialized, either set to a specific IP version
 *     (AF_INET/AF_INET6) or to the unspecified AF_UNSPEC (= 0), if both
 *     IP versions are acceptable
 *  extra can be NULL and is only set in special circumstances, see returns
 *
 * returns in *to a valid IPAny (v4/v6),
 *     prefers v6 if ip.family was AF_UNSPEC and both available
 * returns in *extra an IPv4 address, if family was AF_UNSPEC and *to is AF_INET6
 * returns 0 on failure, TOX_ADDR_RESOLVE_* on success.
 */
int addr_resolve(const char *address, IP *to, IP *extra)
{
    if (!address || !to) {
        return 0;
    }

    sa_family_t family = to->family;

    struct addrinfo *server = NULL;
    struct addrinfo *walker = NULL;
    struct addrinfo  hints;
    int rc;
    int result = 0;
    int done = 0;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family   = family;
    hints.ai_socktype = SOCK_DGRAM; // type of socket Tox uses.

    if (networking_at_startup() != 0) {
        return 0;
    }

    rc = getaddrinfo(address, NULL, &hints, &server);

    // Lookup failed.
    if (rc != 0) {
        return 0;
    }

    IP ip4;
    ip_init(&ip4, 0); // ipv6enabled = 0
    IP ip6;
    ip_init(&ip6, 1); // ipv6enabled = 1

    for (walker = server; (walker != NULL) && !done; walker = walker->ai_next) {
        switch (walker->ai_family) {
            case AF_INET:
                if (walker->ai_family == family) { /* AF_INET requested, done */
                    struct sockaddr_in *addr = (struct sockaddr_in *)walker->ai_addr;
                    get_ip4(&to->ip4, &addr->sin_addr);
                    result = TOX_ADDR_RESOLVE_INET;
                    done = 1;
                } else if (!(result & TOX_ADDR_RESOLVE_INET)) { /* AF_UNSPEC requested, store away */
                    struct sockaddr_in *addr = (struct sockaddr_in *)walker->ai_addr;
                    get_ip4(&ip4.ip4, &addr->sin_addr);
                    result |= TOX_ADDR_RESOLVE_INET;
                }

                break; /* switch */

            case AF_INET6:
                if (walker->ai_family == family) { /* AF_INET6 requested, done */
                    if (walker->ai_addrlen == sizeof(struct sockaddr_in6)) {
                        struct sockaddr_in6 *addr = (struct sockaddr_in6 *)walker->ai_addr;
                        get_ip6(&to->ip6, &addr->sin6_addr);
                        result = TOX_ADDR_RESOLVE_INET6;
                        done = 1;
                    }
                } else if (!(result & TOX_ADDR_RESOLVE_INET6)) { /* AF_UNSPEC requested, store away */
                    if (walker->ai_addrlen == sizeof(struct sockaddr_in6)) {
                        struct sockaddr_in6 *addr = (struct sockaddr_in6 *)walker->ai_addr;
                        get_ip6(&ip6.ip6, &addr->sin6_addr);
                        result |= TOX_ADDR_RESOLVE_INET6;
                    }
                }

                break; /* switch */
        }
    }

    if (family == AF_UNSPEC) {
        if (result & TOX_ADDR_RESOLVE_INET6) {
            ip_copy(to, &ip6);

            if ((result & TOX_ADDR_RESOLVE_INET) && (extra != NULL)) {
                ip_copy(extra, &ip4);
            }
        } else if (result & TOX_ADDR_RESOLVE_INET) {
            ip_copy(to, &ip4);
        } else {
            result = 0;
        }
    }

    freeaddrinfo(server);
    return result;
}

/*
 * addr_resolve_or_parse_ip
 *  resolves string into an IP address
 *
 *  address: a hostname (or something parseable to an IP address)
 *  to: to.family MUST be initialized, either set to a specific IP version
 *     (AF_INET/AF_INET6) or to the unspecified AF_UNSPEC (= 0), if both
 *     IP versions are acceptable
 *  extra can be NULL and is only set in special circumstances, see returns
 *
 *  returns in *tro a matching address (IPv6 or IPv4)
 *  returns in *extra, if not NULL, an IPv4 address, if to->family was AF_UNSPEC
 *  returns 1 on success
 *  returns 0 on failure
 */
int addr_resolve_or_parse_ip(const char *address, IP *to, IP *extra)
{
    if (!addr_resolve(address, to, extra)) {
        if (!addr_parse_ip(address, to)) {
            return 0;
        }
    }

    return 1;
}
