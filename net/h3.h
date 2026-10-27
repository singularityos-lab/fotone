#include <ngtcp2/ngtcp2.h>
#include <ngtcp2/ngtcp2_crypto.h>
#include <ngtcp2/ngtcp2_crypto_gnutls.h>
#include <nghttp3/nghttp3.h>
#include <gnutls/gnutls.h>
#include <gnutls/crypto.h>
#include <netdb.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <sys/eventfd.h>
#define GLIB_VERSION_MIN_REQUIRED (G_ENCODE_VERSION (2, 40))
#define GLIB_VERSION_MAX_ALLOWED (G_ENCODE_VERSION (2, 42))
#define __GLIB_H_INSIDE__ 1
#include <glib/gmacros.h>
#undef __GLIB_H_INSIDE__
#undef G_GNUC_BEGIN_IGNORE_DEPRECATIONS
#undef G_GNUC_END_IGNORE_DEPRECATIONS
#define G_GNUC_BEGIN_IGNORE_DEPRECATIONS
#define G_GNUC_END_IGNORE_DEPRECATIONS
#include <glib.h>
