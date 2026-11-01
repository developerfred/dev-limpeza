#ifndef DCC_H
#define DCC_H

/// Scans `root` for development caches. Returns a malloc'd JSON array
/// [{path,label,size,idle_days}], largest first, or NULL on error. Free with dcc_free.
char *dcc_scan(const char *root);
void dcc_free(char *p);

#endif
