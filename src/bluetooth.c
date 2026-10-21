#define _NETBSD_SOURCE
#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <lua.h>
#include <lauxlib.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifdef __NetBSD__
#include <sys/endian.h>
#include <bluetooth.h>
#include <netbt/l2cap.h>
#endif
#define OUTPUT_LIMIT 65536
#define PCM_BYTES (882 * 4)
#define CONNECTION_META "asenta.bluetooth.connection"
#define ADMIN "/opt/oxtorg/bin/oxtorg-bluetooth-admin"
struct child { pid_t pid; int input, output, code, slot, admin; };
struct session {
    struct child child;
    pthread_mutex_t mutex;
    pthread_t worker;
    int started, stop, connected, audio, packets, fd, probing;
    char address[18], profile[16], line[8192], tail[8192];
    size_t line_size, tail_size, pending, sent;
    unsigned char pcm[PCM_BYTES];
    int tone_frame;
    int64_t next_pcm, write_deadline, probe_due, probe_deadline;
};
struct connection { struct session *active; int closed; };
#ifdef BLUETOOTH_NATIVE_TEST
#include <lualib.h>
static char test_dir[PATH_MAX];
static int test_timeout;
#endif
#define CHILD_SLOTS 16
static sig_atomic_t child_pids[CHILD_SLOTS];
static void block_signals(sigset_t *previous) {
    sigset_t blocked; sigemptyset(&blocked);
    sigaddset(&blocked,SIGINT); sigaddset(&blocked,SIGTERM);
    pthread_sigmask(SIG_BLOCK,&blocked,previous);
}
/* PIDs remain reserved until their published slot is cleared before waitpid. */
void host_bluetooth_signal(int signal_number) {
    (void)signal_number;
    int saved=errno;
    for (int i=0;i<CHILD_SLOTS;++i) {
        pid_t pid=(pid_t)__atomic_load_n(&child_pids[i],__ATOMIC_RELAXED);
        if (pid>0) kill(-pid,SIGKILL);
    }
    /* Process exit closes the cancellation pipe of any root helper. */
    errno=saved;
}
static void child_forget(struct child *child) {
    if (child->slot>=0) __atomic_store_n(&child_pids[child->slot],0,__ATOMIC_RELAXED);
    child->slot=-1;
}
static int64_t now_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}
static void close_fd(int *fd) { if (*fd >= 0) close(*fd); *fd = -1; }
static int nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL);
    return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}
static void child_init(struct child *child) {
    memset(child, 0, sizeof *child); child->input = child->output = child->slot = -1;
}
/* Reserve the leader PID until the whole group has been terminated. */
static int child_reap(struct child *child) {
    if (!child->pid) return 1;
    siginfo_t info;
    memset(&info, 0, sizeof info);
    if (waitid(P_PID, (id_t)child->pid, &info, WEXITED | WNOHANG | WNOWAIT) < 0) {
        if (errno == EINTR) return 0;
        if (errno != ECHILD) return -1;
        child_forget(child); child->pid = 0; child->code = 255;
    } else {
        if (!info.si_pid) return 0;
        kill(-child->pid, SIGKILL);
        child_forget(child);
        int status;
        pid_t got;
        do { got = waitpid(child->pid, &status, 0); } while (got < 0 && errno == EINTR);
        child->code = got > 0 ? (WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status)) : 255;
        child->pid = 0;
    }
    close_fd(&child->input);
    return 1;
}
static void child_close(struct child *child) {
    /* EOF cancels the setuid helper, whose children cannot be signalled by us. */
    close_fd(&child->input);
    if (child->admin && child->pid) {
        /* Give the privileged supervisor time to reap on EOF, even in test
         * builds where it shares our UID and could be killed too early. */
        int64_t until=now_ms()+1000;
        while (child->pid && now_ms()<until) {
            if (child_reap(child)!=0) break;
            poll(NULL,0,10);
        }
    }
    if (child->pid) {
        kill(-child->pid, SIGKILL);
        child_forget(child);
        int status;
        while (waitpid(child->pid, &status, 0) < 0 && errno == EINTR) {}
        child->pid = 0;
    }
    close_fd(&child->input); close_fd(&child->output);
}
static int pipe_pair(int fds[2]) {
    if (pipe(fds) < 0) return -1;
    for (int i = 0; i < 2; ++i) {
        if (fds[i] < 3) {
            int next = fcntl(fds[i], F_DUPFD, 3);
            if (next < 0) return -1;
            close(fds[i]); fds[i] = next;
        }
        if (fcntl(fds[i], F_SETFD, FD_CLOEXEC) < 0) return -1;
    }
    return 0;
}
static int child_start(char **argv, struct child *child) {
    char *run[12]; size_t count=0;
    while (argv[count] && count<sizeof run/sizeof run[0]-1) { run[count]=argv[count]; ++count; }
    if (argv[count]) { errno=EINVAL; return -1; }
    run[count]=NULL;
    child->admin=!strcmp(argv[0],ADMIN);
#ifdef BLUETOOTH_NATIVE_TEST
    char program[PATH_MAX];
    if (test_dir[0]) {
        const char *base = strrchr(argv[0], '/');
        if (snprintf(program, sizeof program, "%s/%s", test_dir, base ? base + 1 : argv[0]) >= (int)sizeof program) {
            errno = ENAMETOOLONG; return -1;
        }
        run[0] = program;
    }
#endif
    int pipes[4] = {-1,-1,-1,-1}, error;
    if (pipe_pair(pipes) < 0 || pipe_pair(pipes+2) < 0) { error = errno; goto failed; }
    if (nonblock(pipes[1]) < 0 || nonblock(pipes[2]) < 0) { error = errno; goto failed; }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    if ((error = posix_spawn_file_actions_init(&actions))) goto failed;
    if ((error = posix_spawnattr_init(&attributes))) goto actions_failed;
    if ((error = posix_spawn_file_actions_adddup2(&actions, pipes[0], STDIN_FILENO)) ||
        (error = posix_spawn_file_actions_adddup2(&actions, pipes[3], STDOUT_FILENO)) ||
        (error = posix_spawn_file_actions_adddup2(&actions, pipes[3], STDERR_FILENO))) goto attributes_failed;
    /* All descriptors created by this module are close-on-exec. */
    for (int i = 0; i < 4; ++i)
        if ((error = posix_spawn_file_actions_addclose(&actions, pipes[i]))) goto attributes_failed;
    sigset_t empty, defaults;
    sigemptyset(&empty); sigemptyset(&defaults);
    sigaddset(&defaults, SIGPIPE); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT);
    if ((error = posix_spawnattr_setsigmask(&attributes, &empty)) ||
        (error = posix_spawnattr_setsigdefault(&attributes, &defaults)) ||
        (error = posix_spawnattr_setpgroup(&attributes, 0)) ||
        (error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))) goto attributes_failed;
    char *environment[] = {"PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/pkg/bin", "LC_ALL=C", NULL};
    sigset_t previous;
    block_signals(&previous);
    int slot;
    for (slot=0;slot<CHILD_SLOTS;++slot)
        if (!__atomic_load_n(&child_pids[slot],__ATOMIC_RELAXED)) break;
    error=slot==CHILD_SLOTS ? EAGAIN : posix_spawn(&child->pid,run[0],&actions,&attributes,run,environment);
    if (!error) {
        child->slot=slot;
        __atomic_store_n(&child_pids[slot],(sig_atomic_t)(child->admin?-child->pid:child->pid),__ATOMIC_RELAXED);
    }
    pthread_sigmask(SIG_SETMASK,&previous,NULL);
    if (!error) {
        child->input = pipes[1]; child->output = pipes[2];
        close(pipes[0]); close(pipes[3]);
        posix_spawnattr_destroy(&attributes); posix_spawn_file_actions_destroy(&actions);
        return 0;
    }
attributes_failed:
    posix_spawnattr_destroy(&attributes);
actions_failed:
    posix_spawn_file_actions_destroy(&actions);
failed:
    for (int i = 0; i < 4; ++i) if (pipes[i] >= 0) close(pipes[i]);
    errno = error; return -1;
}
#if defined(BLUETOOTH_NATIVE_TEST) || defined(__NetBSD__)
static int wait_fd(int fd, short events, int64_t until) {
    for (;;) {
        int64_t left = until - now_ms();
        if (left <= 0) { errno = ETIMEDOUT; return -1; }
        struct pollfd descriptor = {fd, events, 0};
        int ready = poll(&descriptor, 1, left > 20 ? 20 : (int)left);
        if (ready > 0) return 0;
        if (ready < 0 && errno != EINTR) return -1;
    }
}
#endif
static struct connection *connection(lua_State *L) {
    struct connection *self = luaL_checkudata(L, 1, CONNECTION_META);
    luaL_argcheck(L, !self->closed, 1, "Bluetooth connection is closed");
    return self;
}
static const char *address_arg(lua_State *L, int index) {
    size_t size;
    const char *address = luaL_checklstring(L, index, &size);
    int valid = size == 17;
    for (size_t i = 0; valid && i < size; ++i)
        if ((i % 3 == 2) ? address[i] != ':' : !isxdigit((unsigned char)address[i])) valid = 0;
    luaL_argcheck(L, valid, index, "a selected Bluetooth address is required");
    return address;
}
static const char *choice(lua_State *L, int index, const char *fallback, const char *a, const char *b, const char *c) {
    size_t size;
    const char *value = luaL_optlstring(L, index, fallback, &size);
    if (!size) value = fallback;
    luaL_argcheck(L,
        ((!strcmp(value,a)) || (b && !strcmp(value,b)) || (c && !strcmp(value,c))) &&
        (size == 0 || size == strlen(value)), index, "unsupported Bluetooth option");
    return value;
}
/* Fixed argv only: ordinary Lua code cannot turn this into a shell runner. */
static int native_command(lua_State *L) {
    (void)connection(L);
    size_t action_size;
    const char *action = luaL_checklstring(L, 2, &action_size);
    luaL_argcheck(L,action_size==strlen(action),2,"invalid Bluetooth command");
    char *argv[10] = {0};
    int limit;
    if (!strcmp(action,"status")) {
        argv[0]="/usr/sbin/btconfig"; argv[1]="-v"; argv[2]="btuart0"; limit=5000;
    } else if (!strcmp(action,"summary")) {
        argv[0]="/usr/sbin/btconfig"; argv[1]="btuart0"; limit=5000;
    } else if (!strcmp(action,"state")) {
        argv[0]=ADMIN; argv[1]="state"; limit=10000;
    } else if (!strcmp(action,"power")) {
        luaL_checktype(L, 3, LUA_TBOOLEAN);
        argv[0]=ADMIN; argv[1]="power"; argv[2]=lua_toboolean(L,3)?"on":"off"; limit=25000;
    } else if (!strcmp(action,"discover")) {
        argv[0]="/usr/sbin/btconfig"; argv[1]="btuart0"; argv[2]="inquiry"; limit=45000;
    } else if (!strcmp(action,"services")) {
        argv[0]="/usr/bin/sdpquery"; argv[1]="-d"; argv[2]="btuart0"; argv[3]="-a";
        argv[4]=(char *)address_arg(L,3); argv[5]="Browse"; limit=30000;
    } else if (!strcmp(action,"pair")) {
        argv[0]=ADMIN; argv[1]="pair"; argv[2]=(char *)address_arg(L,3);
        argv[3]=(char *)choice(L,4,"bonded","bonded","just-works","legacy-pin"); limit=110000;
    } else return luaL_error(L,"unknown Bluetooth command");
#ifdef BLUETOOTH_NATIVE_TEST
    if (test_timeout) limit=test_timeout;
#endif
    /* Allocate before spawning; no Lua allocation owns an untracked child. */
    char *output = lua_newuserdatauv(L, OUTPUT_LIMIT+1, 0);
    struct child child; child_init(&child);
    if (child_start(argv, &child) < 0) return luaL_error(L,"Bluetooth command: %s",strerror(errno));
    size_t size=0;
    int error=0;
    int64_t until=now_ms()+limit;
    while (child.pid || child.output >= 0) {
        if (now_ms() >= until) { error=ETIMEDOUT; break; }
        struct pollfd descriptor={child.output,POLLIN,0};
        int ready=poll(&descriptor,1,20);
        if (ready<0 && errno!=EINTR) { error=errno; break; }
        if (ready>0 && child.output>=0) {
            char block[4096];
            ssize_t n=read(child.output,block,sizeof block);
            if (n>0) {
                if ((size_t)n>OUTPUT_LIMIT-size) { error=EOVERFLOW; break; }
                memcpy(output+size,block,(size_t)n); size+=(size_t)n;
            } else if (!n) close_fd(&child.output);
            else if (errno!=EINTR && errno!=EAGAIN && errno!=EWOULDBLOCK) { error=errno; break; }
        }
        if (child_reap(&child)<0) { error=errno; break; }
    }
    child_close(&child); output[size]=0;
    if (error || child.code) return luaL_error(L,"%s; %s",
        error ? (error==EOVERFLOW ? "Bluetooth command output exceeded 64 KiB" : strerror(error)) : "Bluetooth command failed",output);
    lua_pushlstring(L,output,size); return 1;
}
static void remember(struct session *s, const char *bytes, size_t count) {
    if (count>=sizeof s->tail) { bytes+=count-sizeof s->tail+1; count=sizeof s->tail-1; }
    size_t discard=s->tail_size+count>=sizeof s->tail ? s->tail_size+count-sizeof s->tail+1 : 0;
    if (discard) { memmove(s->tail,s->tail+discard,s->tail_size-discard); s->tail_size-=discard; }
    memcpy(s->tail+s->tail_size,bytes,count); s->tail_size+=count; s->tail[s->tail_size]=0;
}
static int audio_output(struct session *s) {
    char block[4096];
    for (int pass=0;s->child.output>=0 && pass<8;++pass) {
        ssize_t n=read(s->child.output,block,sizeof block);
        if (!n) { close_fd(&s->child.output); break; }
        if (n<0) {
            if (errno==EINTR || errno==EAGAIN || errno==EWOULDBLOCK) break;
            return -1;
        }
        remember(s,block,(size_t)n);
        for (ssize_t i=0;i<n;++i) {
            if (block[i]=='\n') {
                s->line[s->line_size]=0;
                while (s->line_size && (s->line[s->line_size-1]=='\r' || s->line[s->line_size-1]==' ')) s->line[--s->line_size]=0;
                if (!strcmp(s->line,"Responded to command 7")) s->connected=1;
                unsigned int bytes;
                if (sscanf(s->line,"Streaming %u bytes",&bytes)==1 && bytes && s->packets<INT_MAX) ++s->packets;
                s->line_size=0;
            } else {
                if (s->line_size>=sizeof s->line-1) { errno=EOVERFLOW; return -1; }
                s->line[s->line_size++]=block[i];
            }
        }
    }
    return 0;
}
static void pcm_chunk(struct session *s) {
    memset(s->pcm,0,sizeof s->pcm);
    if (s->tone_frame>=0 && s->tone_frame<88200) {
        for (int i=0;i<882;++i) {
            int frame=s->tone_frame++;
            double fade=fmin(1.0,fmin(frame,88199-frame)/2205.0);
            int16_t sample=(int16_t)(12000.0*fade*sin(2.0*3.141592653589793*440.0*frame/44100.0));
            for (int channel=0;channel<2;++channel) {
                s->pcm[i*4+channel*2]=(unsigned char)((uint16_t)sample&255);
                s->pcm[i*4+channel*2+1]=(unsigned char)((uint16_t)sample>>8);
            }
        }
    }
    s->pending=sizeof s->pcm; s->sent=0; s->write_deadline=now_ms()+15000;
}
static int audio_tick(struct session *s) {
    if (audio_output(s)<0 || child_reap(&s->child)!=0) return -1;
    int64_t now=now_ms();
    if (!s->pending && now>=s->next_pcm) pcm_chunk(s);
    if (s->pending) {
        ssize_t n=write(s->child.input,s->pcm+s->sent,s->pending-s->sent);
        if (n>0) {
            s->sent+=(size_t)n;
            if (s->sent==s->pending) { s->pending=0; s->next_pcm=now+20; }
        } else if (now>=s->write_deadline || (n<0 && errno!=EINTR && errno!=EAGAIN && errno!=EWOULDBLOCK)) return -1;
    }
    return 0;
}
static unsigned int big16(const unsigned char *p) { return ((unsigned int)p[0]<<8)|p[1]; }
static int sdp_reply_valid(const unsigned char *reply, size_t size) {
    if (size<10 || reply[0]!=3 || reply[1]!=0x4b || reply[2]!=0x56 || big16(reply+3)!=size-5) return 0;
    size_t count=big16(reply+7);
    if (count!=1 || big16(reply+5)<count) return 0;
    size_t offset=9+count*4;
    return offset<size && reply[offset]<=16 && size==offset+1+reply[offset];
}
static int diagnostic_tick(struct session *s) {
    int64_t now=now_ms();
    if (!s->probing && now>=s->probe_due) {
        const unsigned char request[]={2,0x4b,0x56,0,8,0x35,3,0x19,1,0,0,1,0};
        ssize_t sent=send(s->fd,request,sizeof request,0);
        if (sent<0 && (errno==EINTR || errno==EAGAIN || errno==EWOULDBLOCK)) return 0;
        if (sent!=(ssize_t)sizeof request) return -1;
        s->probing=1; s->probe_deadline=now+5000;
    }
    struct pollfd descriptor={s->fd,POLLIN,0};
    int ready=poll(&descriptor,1,0);
    if (ready<0 && errno!=EINTR) return -1;
    if (ready>0) {
        unsigned char response[128];
        ssize_t count=recv(s->fd,response,sizeof response,0);
        if (count<0 && (errno==EINTR || errno==EAGAIN || errno==EWOULDBLOCK)) return 0;
        if (!s->probing || count<=0 || !sdp_reply_valid(response,(size_t)count)) return -1;
        s->connected=1; s->probing=0; s->probe_due=now+15000;
    }
    if (s->probing && now>=s->probe_deadline) return -1;
    return 0;
}
/* Only active sessions allocate a small worker stack; it never calls Lua. */
static void *session_worker(void *argument) {
    struct session *s=argument;
    sigset_t blocked; sigemptyset(&blocked); sigaddset(&blocked,SIGPIPE);
    pthread_sigmask(SIG_BLOCK,&blocked,NULL);
    for (;;) {
        pthread_mutex_lock(&s->mutex);
        int stopped=s->stop;
        if (!stopped && (s->audio ? audio_tick(s) : diagnostic_tick(s))<0) {
            s->connected=0; s->stop=1; stopped=1;
        }
        pthread_mutex_unlock(&s->mutex);
        if (stopped) break;
        poll(NULL,0,10);
    }
    pthread_mutex_lock(&s->mutex);
    s->connected=0; child_close(&s->child); close_fd(&s->fd);
    pthread_mutex_unlock(&s->mutex);
    return NULL;
}
static void session_disconnect(struct connection *self) {
    struct session *s=self->active;
    if (!s) return;
    if (s->started) {
        pthread_mutex_lock(&s->mutex); s->stop=1; pthread_mutex_unlock(&s->mutex);
        pthread_join(s->worker,NULL);
    }
    child_close(&s->child); close_fd(&s->fd);
    pthread_mutex_destroy(&s->mutex); free(s); self->active=NULL;
}
static int native_disconnect(lua_State *L) { session_disconnect(connection(L)); return 0; }
static int native_close(lua_State *L) {
    struct connection *self=luaL_checkudata(L,1,CONNECTION_META);
    session_disconnect(self); self->closed=1; return 0;
}
static int native_state(lua_State *L) {
    struct session *s=connection(L)->active;
    if (!s) { lua_pushnil(L); return 1; }
    /* Do not keep the mutex across a Lua allocation/longjmp. */
    pthread_mutex_lock(&s->mutex);
    int connected=s->connected,packets=s->packets;
    pthread_mutex_unlock(&s->mutex);
    lua_newtable(L);
    lua_pushstring(L,s->address); lua_setfield(L,-2,"address");
    lua_pushstring(L,s->profile); lua_setfield(L,-2,"profile");
    lua_pushboolean(L,connected); lua_setfield(L,-2,"connected");
    if (packets) { lua_pushinteger(L,packets); lua_setfield(L,-2,"audioPackets"); }
    return 1;
}
static int diagnostic_open(struct session *s) {
#ifdef BLUETOOTH_NATIVE_TEST
    struct sockaddr_un peer;
    memset(&peer,0,sizeof peer); peer.sun_family=AF_UNIX;
    if (snprintf(peer.sun_path,sizeof peer.sun_path,"%s/diagnostic.sock",test_dir)>=(int)sizeof peer.sun_path) { errno=ENAMETOOLONG; return -1; }
    s->fd=socket(AF_UNIX,SOCK_STREAM,0);
#elif defined(__NetBSD__)
    struct sockaddr_bt peer={0},local={0};
    local.bt_len=peer.bt_len=sizeof local;
    local.bt_family=peer.bt_family=AF_BLUETOOTH;
    peer.bt_psm=htole16(L2CAP_PSM_SDP);
    if (!bt_devaddr("btuart0",&local.bt_bdaddr) || !bt_aton(s->address,&peer.bt_bdaddr)) return -1;
    s->fd=socket(PF_BLUETOOTH,SOCK_SEQPACKET,BTPROTO_L2CAP);
    int mode=L2CAP_LM_AUTH|L2CAP_LM_ENCRYPT;
    if (s->fd<0 || setsockopt(s->fd,BTPROTO_L2CAP,SO_L2CAP_LM,&mode,sizeof mode)<0 || bind(s->fd,(struct sockaddr *)&local,sizeof local)<0) return -1;
#else
    (void)s; errno=ENOTSUP; return -1;
#endif
#if defined(BLUETOOTH_NATIVE_TEST) || defined(__NetBSD__)
    if (s->fd<0 || fcntl(s->fd,F_SETFD,FD_CLOEXEC)<0 || nonblock(s->fd)<0) return -1;
    if (connect(s->fd,(struct sockaddr *)&peer,sizeof peer)<0) {
        if (errno!=EINPROGRESS || wait_fd(s->fd,POLLOUT,now_ms()+20000)<0) return -1;
        int error=0; socklen_t length=sizeof error;
        if (getsockopt(s->fd,SOL_SOCKET,SO_ERROR,&error,&length)<0) return -1;
        if (error) { errno=error; return -1; }
    }
    return 0;
#endif
}
static int native_connect(lua_State *L) {
    struct connection *self=connection(L);
    const char *address=address_arg(L,2);
    const char *profile=choice(L,3,"diagnostic","diagnostic","audio",NULL);
    if (self->active) {
        pthread_mutex_lock(&self->active->mutex); int connected=self->active->connected; pthread_mutex_unlock(&self->active->mutex);
        luaL_argcheck(L,!connected,1,"disconnect the current Bluetooth peer first");
        session_disconnect(self);
    }
    struct session *s=calloc(1,sizeof *s);
    if (!s) return luaL_error(L,"Bluetooth session: out of memory");
    child_init(&s->child); s->fd=-1; s->tone_frame=-1;
    int error=pthread_mutex_init(&s->mutex,NULL);
    if (error) { free(s); return luaL_error(L,"Bluetooth session: %s",strerror(error)); }
    self->active=s;
    strcpy(s->address,address); strcpy(s->profile,profile); s->audio=!strcmp(profile,"audio");
    if (s->audio) {
        char *argv[]={"/opt/oxtorg/bin/bluetooth-a2dp","-v","-d","btuart0","-a",s->address,"-m","encrypt","-B","8",NULL};
        if (child_start(argv,&s->child)<0) error=errno;
    } else if (diagnostic_open(s)<0) error=errno;
    if (!error) {
        pthread_attr_t attributes;
        error=pthread_attr_init(&attributes);
        if (!error) {
            error=pthread_attr_setstacksize(&attributes,64*1024);
            if (!error) {
                sigset_t previous; block_signals(&previous);
                error=pthread_create(&s->worker,&attributes,session_worker,s);
                pthread_sigmask(SIG_SETMASK,&previous,NULL);
            }
            pthread_attr_destroy(&attributes);
        }
        if (!error) s->started=1;
    }
    if (error) { session_disconnect(self); return luaL_error(L,"Bluetooth profile: %s",strerror(error)); }
    int64_t until=now_ms()+100000;
#ifdef BLUETOOTH_NATIVE_TEST
    if (test_timeout) until=now_ms()+test_timeout;
#endif
    while (now_ms()<until) {
        pthread_mutex_lock(&s->mutex); int connected=s->connected,stopped=s->stop; pthread_mutex_unlock(&s->mutex);
        if (connected) { lua_pushboolean(L,1); return 1; }
        if (stopped) break;
        poll(NULL,0,10);
    }
    char why[sizeof s->tail];
    pthread_mutex_lock(&s->mutex); strcpy(why,s->tail); pthread_mutex_unlock(&s->mutex);
    session_disconnect(self);
    return luaL_error(L,"Bluetooth profile did not connect: %s",why);
}
static int native_tone(lua_State *L) {
    struct session *s=connection(L)->active;
    luaL_argcheck(L,s && s->audio,1,"connect an audio device first");
    pthread_mutex_lock(&s->mutex); int connected=s->connected; if (connected) s->tone_frame=0; pthread_mutex_unlock(&s->mutex);
    luaL_argcheck(L,connected,1,"audio device disconnected");
    int64_t until=now_ms()+19000;
    while (now_ms()<until) {
        pthread_mutex_lock(&s->mutex);
        connected=s->connected; int complete=s->tone_frame>=88200 && !s->pending;
        if (!connected || complete) s->tone_frame=-1;
        pthread_mutex_unlock(&s->mutex);
        if (!connected) return luaL_error(L,"audio device disconnected");
        if (complete) { lua_pushboolean(L,1); return 1; }
        poll(NULL,0,5);
    }
    pthread_mutex_lock(&s->mutex); s->tone_frame=-1; pthread_mutex_unlock(&s->mutex);
    return luaL_error(L,"Bluetooth audio test timed out");
}
static int native_open(lua_State *L) {
    struct connection *self=lua_newuserdatauv(L,sizeof *self,0);
    memset(self,0,sizeof *self); luaL_setmetatable(L,CONNECTION_META); return 1;
}
int luaopen_asenta_bluetooth(lua_State *L) {
    const luaL_Reg methods[]={{"command",native_command},{"state",native_state},{"connect",native_connect},
        {"disconnect",native_disconnect},{"tone",native_tone},{"close",native_close},{"__close",native_close},{"__gc",native_close},{NULL,NULL}};
    luaL_newmetatable(L,CONNECTION_META); luaL_setfuncs(L,methods,0); lua_pushvalue(L,-1); lua_setfield(L,-2,"__index"); lua_pop(L,1);
    lua_newtable(L); lua_pushcfunction(L,native_open); lua_setfield(L,-2,"open"); return 1;
}
#ifdef BLUETOOTH_NATIVE_TEST
static void test_signal(int number) { host_bluetooth_signal(number); _exit(128+number); }
int main(int argc,char **argv) {
    if (argc<3 || argc>4 || strlen(argv[1])>=sizeof test_dir) return 2;
    strcpy(test_dir,argv[1]); if (argc==4) test_timeout=atoi(argv[3]);
    lua_State *L=luaL_newstate(); if (!L) return 1;
    signal(SIGINT,test_signal); signal(SIGTERM,test_signal);
    luaL_openlibs(L); luaL_requiref(L,"asenta.bluetooth",luaopen_asenta_bluetooth,0); lua_pop(L,1);
    int result=luaL_loadfile(L,argv[2]);
    if (result==LUA_OK) result=lua_pcall(L,0,0,0);
    if (result!=LUA_OK) fprintf(stderr,"%s\n",lua_tostring(L,-1));
    lua_close(L); return result==LUA_OK?0:1;
}
#endif
