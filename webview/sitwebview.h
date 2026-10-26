#ifndef SIT_WEB_VIEW_H
#define SIT_WEB_VIEW_H

#include <gtk/gtk.h>
#include <wpe/webkit.h>

G_BEGIN_DECLS

#define SIT_TYPE_WEB_VIEW (sit_web_view_get_type ())

typedef struct _SitWebView SitWebView;

GType          sit_web_view_get_type     (void);
GtkWidget     *sit_web_view_new          (void);
GtkWidget     *sit_web_view_new_with_web_view (WebKitWebView *web_view);
WPEDisplay    *sit_web_view_get_display  (void);
WebKitWebView *sit_web_view_get_web_view (SitWebView *self);
void           sit_web_view_load_uri     (SitWebView *self,
                                          const char *uri);
void           sit_web_view_set_transparent (SitWebView *self,
                                             gboolean    transparent);
gboolean       sit_web_view_get_transparent (SitWebView *self);
GdkTexture    *sit_web_view_get_frame    (SitWebView *self);
gboolean       sit_web_view_show_devtools (SitWebView *self);
void           sit_web_view_translate    (SitWebView *self);
void           sit_web_view_set_passwords (SitWebView *self,
                                           gboolean    enabled);
gboolean       sit_web_view_get_passwords (SitWebView *self);
GtkWidget     *sit_web_view_new_for_web_app (const char *app_id);
char          *sit_web_view_install_web_app (SitWebView *self,
                                             const char *name,
                                             GError    **error);

void           sit_web_view_print        (SitWebView       *self,
                                          GtkWindow        *parent,
                                          GtkPrintSettings *settings,
                                          GtkPageSetup     *page_setup,
                                          gboolean          dialog,
                                          void            (*done) (gpointer user_data, gboolean printed),
                                          gpointer          user_data);

gboolean       sit_web_view_install_rule_set (const char *id,
                                              const char *rules,
                                              void      (*done) (gboolean compiled, const GError *error, gpointer user_data),
                                              gpointer    user_data,
                                              GError    **error);
void           sit_web_view_remove_rule_set (const char *id);

char          *sit_web_view_install_extension (const char  *path,
                                               GError     **error);
void           sit_web_view_remove_extension  (const char  *id);

G_END_DECLS

#endif
