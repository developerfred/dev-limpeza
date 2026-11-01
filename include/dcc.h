#ifndef DCC_H
#define DCC_H

/// Scans `root` for development caches. Returns a malloc'd JSON array
/// [{path,label,size,idle_days}], largest first, or NULL on error. Free with dcc_free.
char *dcc_scan(const char *root);
/// Sizes known global tool caches (package managers, AI agents, editors, Xcode).
/// Returns a malloc'd JSON array [{id,tool,name,path,description,loses,category,risk,size}] or NULL.
char *dcc_scan_global(void);
void dcc_free(char *p);

#endif
