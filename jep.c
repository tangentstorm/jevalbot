/*
jep -- implements the j socket protocol from the j602 interpreter engine

Copyright (C) 2008 Zsban Ambrus

*/


#define _GNU_SOURCE
#include <netdb.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>


#ifdef __GNUC__
#define _attribute(x) __attribute__(x)
#else
#define _attribute(x)  
#endif

void fatal (const char *s, ...)
	_attribute ((noreturn, format(printf,1,2)));

void fatal (const char *s, ...) {
	va_list va;
	va_start (va, s);
	vfprintf (stderr, s, va);
	va_end (va);
	fprintf (stderr, "\n");
	exit (1);
	}


enum {
	CMDDO = 1, CMDDOZ, CMDIN, CMDINZ, CMDWD, CMDWDZ, CMDOUT, 
	CMDBRK, CMDGET, CMDGETZ, CMDSETN, CMDSET, CMDSETZ, CMDED, CMDFL,
	CMDEXIT,
};
enum {
	OUTFR = 1, OUTERR, OUTLOG, OUTSYS, OUTEXIT, OUTFILE,
};

struct
jarray {
	long jarray_off; // body offset
	long jarray_flag;
	long jarray_m;
	long jarray_type;
	long jarray_c;
	long jarray_nelts; // elements in ravel
	long jarray_rank;
	long jarray_shape[0]; // shape
};

void *JInit(void);
int JFree(void *jsess);
void JSM(void *jsess, void **callbacks);
int JDo(void *jsess, char *);
long JGetM(void *jsess, char *cmd, long *type, long *rank, long **shape, long **data);
long JSetM(void *jsess, char *name, long *type, long *rank, long **shape, long **data);

struct
msghead {
	int8_t major;
	int8_t pad0; int8_t pad1; int8_t pad2;
	int32_t minor;
	int32_t len;
};

static int8_t
msgmajor;
static int32_t
msgminor;
static size_t
msglen;
static size_t
msgbody_len = 0;
static char *
msgbody = 0;

FILE *
chan = 0;

static void *
jsession = 0;

void
resize(void) {
	if (msgbody_len < msglen) {
		msgbody_len = msglen;
		msgbody = realloc(msgbody, msgbody_len + 32);
		if (!msgbody)
			fatal("out of memory for message len %ld", (long)msgbody_len);
	}
}

void
sethead(int8_t major, int32_t minor, int32_t len) {
	msgmajor = major;
	msgminor = minor;
	msglen = len;
	resize();
}

void
read_input(void) {
	static struct msghead msghead;
	int r = fread(&msghead, sizeof(struct msghead), 1, chan);
	if (1 != r)
		fatal("end of file or error reading controlling socket");
	msgmajor = msghead.major;
	msgminor = ntohl(msghead.minor);
	msglen = ntohl(msghead.len);
	//fprintf(stderr, "[INP major=%d minor=%d len=%d]\n", (int)msgmajor, (int)msgminor, (int)msglen);
	resize();
	r = fread(msgbody, msglen, 1, chan);
	if (1 != r)
		fatal("end of file or error reading data from controlling socket");
	//fprintf(stderr, "[OKINP]\n");
}

void
out(void) {
	//fprintf(stderr, "[OUT major=%d minor=%d len=%d]\n", (int)msgmajor, (int)msgminor, (int)msglen);
	static struct msghead msghead;
	msghead.major = msgmajor;
	msghead.minor = htonl(msgminor);
	if (INT32_MAX < msglen)
		fatal("output message too long");
	msghead.len = htonl(msglen);
	int r = fwrite(&msghead, sizeof(struct msghead), 1, chan);
	if (1 != r)
		fatal("error writing controlling socket");
	if (msglen) {
		r = fwrite(msgbody, msglen, 1, chan);
		if (1 != r) 
			fatal("error writing data to controlling socket");
	}
	//fprintf(stderr, "[OKOUT]\n");
}

static void
joutput(void *jsess, int type, char *s) {
	if (5 == type) {
		sethead(CMDEXIT, type, 0);
		out();
		exit((long)s);
	} else {
		size_t l = strlen(s);
		sethead(CMDOUT, type, l);
		memcpy(msgbody, s, l);
		out();
	}
}

static int
jcmdset_name_err = 19;

static void
handle_input(void) {
	switch (msgmajor) {
		case CMDDO: {
			char *cmd = malloc(5+msglen);
			if (!cmd)
				fatal("out of memory copying j command");
			memcpy(cmd, msgbody, msglen);
			cmd[msglen] = 0;
			//fprintf(stderr, "[CMDDO (%s)]\n", cmd);
			int r = JDo(jsession, cmd);
			sethead(CMDDOZ, r, 0);
			out();
			free(cmd);
			break;
		} case CMDGET: {
			//fprintf(stderr, "[CMDGET (%.*s)]\n", (int)msglen, msgbody);
			int r = JDo(jsession, "res_jep_=:`");
			if (r) {
				sethead(CMDGETZ, r, 0);
				out();
				break;
			}
			char *cmd = malloc(25+msglen);
			if (!cmd)
				fatal("out of memory copying j command");
			char *t = stpcpy(cmd, "res_jep_=: ");
			memcpy(t, msgbody, msglen);
			t[msglen] = 0;
			r = JDo(jsession, cmd);
			if (r) {
				sethead(CMDGETZ, r, 0);
				out();
				break;
			}
			free(cmd);
			long rep_type = -1, rep_rank = -1, *rep_shape = 0, *rep_data = 0;
			r = JDo(jsession, "rep_jep_=:3 :('assert.0=4!:0<''res_jep_''';'3!:1 res_jep_')0");
			if (r) {
				sethead(CMDGETZ, r, 0);
				out();
				break;
			}
			r = JGetM(jsession, "rep_jep_", &rep_type, &rep_rank, &rep_shape, &rep_data);
			if (r || 2 != rep_type || 1 != rep_rank) {
				sethead(CMDGETZ, r ? r : 19, 0);
				out();
				break;
			}
			sethead(CMDGETZ, 0, rep_shape[0]);
			memcpy(msgbody, rep_data, rep_shape[0]);
			out();
			break;
		} case CMDSETN: {
			//fprintf(stderr, "[CMDSETN (%.*s)]\n", msglen, msgbody);
			long slen = msglen;
			long rep_type = 2, rep_rank = 1, *rep_shape = &slen, *rep_data = (long *)msgbody;
			int r = JSetM(jsession, "nam_jep_", &rep_type, &rep_rank, &rep_shape, &rep_data);
			jcmdset_name_err = r;
			break;
		} case CMDSET: {
			//fprintf(stderr, "[CMDSET]\n");
			if (jcmdset_name_err) {
				sethead(CMDSETZ, jcmdset_name_err, 0);
				out();
				break;
			}
			long slen = msglen;
			long rep_type = 2, rep_rank = 1, *rep_shape = &slen, *rep_data = (long *)msgbody;
			int r = JSetM(jsession, "rep_jep_", &rep_type, &rep_rank, &rep_shape, &rep_data);
			if (r) {
				sethead(CMDSETZ, r, 0);
				out();
				break;
			}
			r = JDo(jsession, "(nam_jep_)=:3!:2 rep_jep_");
			sethead(CMDSETZ, r, 0);
			out();
			break;
		} default:
			fatal("unknown type of input: %d", (int)(msgmajor));
	}
}

static char *
jinput(void *jsess, char *prompt) {
	sethead(CMDIN, 0, strlen(prompt));
	memcpy(msgbody, prompt, msglen);
	out();
	while (read_input(), CMDINZ != msgmajor)
		handle_input();
	msgbody[msglen] = 0;
	//fprintf(stderr, "[CMDINZ (%s)]\n", msgbody);
	return msgbody;
}

static int
jwd(void *jsess, int minor, struct jarray *arg, struct jarray **ret) {
	char *body_char = (char *)arg + arg->jarray_off;
	long *body_long = (long *)body_char;
	fprintf(stderr, "error: jwd request\n");
	fatal("client sent jwd request with arg [arg=%p off=%ld flag=%ld m=%ld type=%ld c=%ld nelts=%ld rank=%ld "
		"shape=(%ld %ld) body_char=(%d %d %d %d) body_long=(%ld %ld)]",
		(void *)arg, 
		arg->jarray_off, arg->jarray_flag, arg->jarray_m, arg->jarray_type, 
		arg->jarray_c, arg->jarray_nelts, arg->jarray_rank, 
		arg->jarray_shape[0], arg->jarray_shape[1],
		body_char[0], body_char[1], body_char[2], body_char[3], body_long[0], body_long[1]
	);
}

static void *
jcallbacks[] = {
	joutput, jwd, jinput, 0, (void *)3
};

static void
cleanup(void) {
	int r;
	if (jsession) {
		r = JFree(jsession);
		if (r)
			fatal("error destroying j interpreter session");
	};
	if (chan) {
		r = fclose(chan);
		if (r < 0) 
			fatal("error closing socket");
	}
}

int 
main(int argc, char **argv) {
	int r;
	msgbody = malloc(1028);
	if (!msgbody)
		fatal("out of memory allocating message body initially");
	msgbody_len = 1024;
	int chanfd = -1;
	if (3 == argc && !strcmp("-jfd", argv[1])) {
		sscanf(argv[2], "%d%n", &chanfd, &r);
		if (strlen(argv[2]) != r)
			fatal("invalid file descriptor number");
	} else if (3 == argc && !strcmp("-jlisten", argv[1])) {
		fatal("sorry, -jlisten option not supported, use -jconnect or -jfd");
	} else if (3 == argc && !strcmp("-jconnect", argv[1])) {
		char *hostports = strdup(argv[2]);
		if (!hostports)
			fatal("out of memory processing argv");
		char *t;
		char *ports;
		char *hosts;
		if ((t = strchr(hostports, ':'))) {
			ports = 1 + t;
			hosts = hostports;
			*t = 0;
		} else {
			ports = hostports;
			hosts = "localhost";
		}
		int port = 0;
		r = -1;
		sscanf(ports, "%d%n", &port, &r);
		if (strlen(ports) != r)
			fatal("invalid port number");
		struct hostent *host = gethostbyname(hosts);
		if (!host)
			fatal("host name not found");
		struct sockaddr_in addr;
		addr.sin_family = AF_INET;
		addr.sin_port = htons(port);
		addr.sin_addr = *(struct in_addr *)(host->h_addr);
		free(hostports);
		chanfd = socket(PF_INET, SOCK_STREAM, 0);
		if (chanfd < 0)
			fatal("error creating socket");
		r = connect(chanfd, (struct sockaddr *)&addr, sizeof(addr));
		if (r < 0)
			fatal("cannot connect socket");
	} else {
		fatal("Usage: jep -jconnect host:port OR jep -jfd filedesno");
	}
	chan = fdopen(chanfd, "r+");
	if (!chan)
		fatal("cannot create file handle for socket");
	r = setvbuf(chan, 0, _IONBF, 0);
	if (r)
		fatal("cannot unbuffer file handle for socket");
	jsession = JInit();
	if (!jsession)
		fatal("error creating j interpreter session");
	JSM(jsession, jcallbacks);
	r = atexit(cleanup);
	if (r)
		fatal("error registering atexit function");
	//fprintf(stderr, "[LOOP]\n");
	while (1) {
		read_input();
		handle_input();
	}
	return 0;
}


// END
