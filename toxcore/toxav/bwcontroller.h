/*
 * Copyright © 2016-2017 The TokTok team.
 * Copyright © 2013-2015 Tox project.
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
#ifndef BWCONROLLER_H
#define BWCONROLLER_H

#include "../toxcore/Messenger.h"

typedef struct BWController_s BWController;

BWController *bwc_new(Messenger *m, uint32_t friendnumber,
                      void (*mcb)(BWController *, uint32_t, float, void *),
                      void *udata);

void bwc_kill(BWController *bwc);

void bwc_add_lost(BWController *bwc, uint32_t bytes);
void bwc_add_recv(BWController *bwc, uint32_t bytes);

#endif /* BWCONROLLER_H */
