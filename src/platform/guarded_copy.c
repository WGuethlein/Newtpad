// Newtpad SEH shim. A copy that runs under Structured Exception Handling so a
// page fault while reading a memory-mapped file - the file was truncated or its
// NTFS decompression failed underneath us - is CAUGHT instead of crashing the
// process (EXCEPTION_IN_PAGE_ERROR). Returns 1 on a clean copy, 0 if a fault
// occurred (the caller then treats that page as unreadable).
//
// No CRT dependency on purpose: the byte loop needs no headers, so the object
// links with nothing and the compile needs no vcvars INCLUDE/LIB set up. Under
// /O2 the loop lowers to a rep-movs / vectorized copy, i.e. memcpy speed on the
// healthy path.
//
// Built by build.bat into build\guarded.obj and foreign-imported by seh.odin.
// __try/__except isn't available in Odin, which is the whole reason this exists.

int newtpad_guarded_copy(void *dst, const void *src, unsigned long long n) {
	__try {
		unsigned char *d = (unsigned char *)dst;
		const unsigned char *s = (const unsigned char *)src;
		for (unsigned long long i = 0; i < n; i++) {
			d[i] = s[i];
		}
		return 1;
	} __except (1 /* EXCEPTION_EXECUTE_HANDLER */) {
		return 0;
	}
}
