/*
 * Utilities.
 */

/*
 * Copyright © 2016-2017 The TokTok team.
 * Copyright © 2013 Tox project.
 * Copyright © 2013 plutooo
 *
 * This file is part of Tox, the free peer to peer instant messenger.
 * This file is donated to the Tox Project.
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
#ifndef UTIL_H
#define UTIL_H

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>

#include "logger.h"

#define MIN(a,b) (((a)<(b))?(a):(b))
#define PAIR(TYPE1__, TYPE2__) struct { TYPE1__ first; TYPE2__ second; }

void unix_time_update(void);
uint64_t unix_time(void);
int is_timeout(uint64_t timestamp, uint64_t timeout);


/* id functions */
bool id_equal(const uint8_t *dest, const uint8_t *src);
uint32_t id_copy(uint8_t *dest, const uint8_t *src); /* return value is CLIENT_ID_SIZE */

void host_to_net(uint8_t *num, uint16_t numbytes);
#define net_to_host(x, y) host_to_net(x, y)

uint16_t lendian_to_host16(uint16_t lendian);
#define host_tolendian16(x) lendian_to_host16(x)

void host_to_lendian32(uint8_t *dest,  uint32_t num);
void lendian_to_host32(uint32_t *dest, const uint8_t *lendian);

/* state load/save */
typedef int (*load_state_callback_func)(void *outer, const uint8_t *data, uint32_t len, uint16_t type);
int load_state(load_state_callback_func load_state_callback, Logger *log, void *outer,
               const uint8_t *data, uint32_t length, uint16_t cookie_inner);

/* Returns -1 if failed or 0 if success */
int create_recursive_mutex(pthread_mutex_t *mutex);

#endif /* UTIL_H */
