#ifndef FOTONE_OPEN_CDM_ADAPTER_H
#define FOTONE_OPEN_CDM_ADAPTER_H

#include <gst/gst.h>
#include "open_cdm.h"

#ifdef __cplusplus
extern "C" {
#endif

OpenCDMError opencdm_gstreamer_session_decrypt(struct OpenCDMSession *session, GstBuffer *buffer, GstBuffer *sub_samples,
                                               const uint32_t sub_sample_count, GstBuffer *iv, GstBuffer *key_id,
                                               uint32_t init_with_last_15);

#ifdef __cplusplus
}
#endif

#endif
