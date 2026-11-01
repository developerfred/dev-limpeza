#ifndef DCC_H
#define DCC_H

#include <stddef.h>

/// Scans `root` for development caches. Returns a malloc'd JSON array
/// [{path,label,size,idle_days}], largest first, or NULL on error. Free with dcc_free.
char *dcc_scan(const char *root);
/// Sizes known global tool caches (package managers, AI agents, editors, Xcode).
/// Returns a malloc'd JSON array [{id,tool,name,path,description,loses,category,risk,size}] or NULL.
char *dcc_scan_global(void);
/// Like dcc_scan_global but does not walk the n absolute catalog paths in skip.
char *dcc_scan_global_partial(const char *const *skip, size_t n);
/// Rescans one subfolder that sits `depth` levels below the original scan root.
char *dcc_scan_sub(const char *root, unsigned int depth);
/// Sizes n directories in parallel (allocated bytes). Returns 0 on success.
int dcc_size_paths(const char *const *paths, size_t n, unsigned long long *out);
void dcc_free(char *p);

#endif
