#ifndef FOTONE_H
#define FOTONE_H

#include <wpe/wpe-platform.h>

G_BEGIN_DECLS

typedef void (*FotoneFrameFunc) (WPEView *view, WPEBuffer *buffer, gpointer user_data);
typedef void (*FotoneAccessibleFunc) (WPEView *view, const char *plug_id, gpointer user_data);
typedef gboolean (*FotoneFullscreenFunc) (WPEToplevel *toplevel, gboolean fullscreen, gpointer user_data);

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
const WPERectangle *fotone_view_get_damage  (WPEView        *view,
                                             guint          *n_rects);
void         fotone_view_set_accessible_func (WPEView             *view,
                                              FotoneAccessibleFunc func,
                                              gpointer             user_data,
                                              GDestroyNotify       destroy);
const char  *fotone_view_get_accessible_plug (WPEView             *view);

void         fotone_toplevel_configure      (WPEToplevel    *toplevel,
                                             int             width,
                                             int             height,
                                             double          scale);

void         fotone_toplevel_set_fullscreen_func (WPEToplevel      *toplevel,
                                                  FotoneFullscreenFunc func,
                                                  gpointer          user_data,
                                                  GDestroyNotify    destroy);
void         fotone_toplevel_set_fullscreened    (WPEToplevel      *toplevel,
                                                  gboolean          fullscreen);

G_END_DECLS

#endif
