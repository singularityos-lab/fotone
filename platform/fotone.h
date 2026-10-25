#ifndef FOTONE_H
#define FOTONE_H

#include <wpe/wpe-platform.h>

G_BEGIN_DECLS

typedef void (*FotoneFrameFunc) (WPEView *view, WPEBuffer *buffer, gpointer user_data);

GType        fotone_display_get_type        (void);
GType        fotone_view_get_type           (void);
GType        fotone_toplevel_get_type       (void);

WPEDisplay  *fotone_display_new             (const char     *render_node);
void         fotone_display_add_format      (WPEDisplay     *display,
                                             guint32         fourcc,
                                             guint64         modifier);
const char  *fotone_display_get_render_node (WPEDisplay     *display);

void         fotone_view_set_frame_func     (WPEView        *view,
                                             FotoneFrameFunc func,
                                             gpointer        user_data,
                                             GDestroyNotify  destroy);
void         fotone_view_frame_presented    (WPEView        *view);

void         fotone_toplevel_configure      (WPEToplevel    *toplevel,
                                             int             width,
                                             int             height,
                                             double          scale);

G_END_DECLS

#endif
