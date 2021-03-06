PID_FILE=/data/local/tmp/sys_logger.pid
MYDIR="$(dirname "$(realpath "$0")")"

# also trace the chrome governor
generate_report=true
trace_cg=false
trace_threads=true
trace_opengl=true
trace_binder=true
trace_record=false
verbose=false
default_interval=5
PARAMS="cpu=2"

fix_ro_filesystem() {
    if [[ $(cat /proc/mounts | grep 'ro,') ]]; then
        echo "File system is read only, fixing"
        # mount -o rw,remount /system
        mount -o rw,remount /
        chmod 777 /system/lib
    fi
}

fix_ro_filesystem

print_usage() {
    echo "Usage: $0 (-v) [setup (-cg) (-nt) (-nb) (-nogl) (-i) | start | stop | finish (-nr)]"
    echo ""
    echo "Syslogger workflow: Setup -> Start -> Stop -> Finish"
    echo ""
    echo "-v            Verbose"
    echo ""
    echo "Setup"
    echo "-cg           Trace Chrome governor"
    echo "-nt           Do not trace threads {sched:sched_process_fork}"
    echo "-nb           Do not trace binder {binder_transaction, cpu_idle, sched_switch}"
    echo "-nogl         Do not trace OpenGL {sys_logger:opengl_frame}"
    echo "-i            Syslogger logging interval, default = 5ms"
    echo "-r            Record straight to a trace.dat"
    echo " "
    echo "Finish"
    echo "-r            Must be given if recording was specified during setup"
    echo "-nr           Do not generate ftrace report (trace.report)"
}

is_loaded() {
    if lsmod | grep -q sys_logger; then
        return 0
    fi
    return 1
}

is_enabled() {
    enabled=$(cat /sys/module/sys_logger/parameters/enabled 2>/dev/null)
    if [ $enabled ]; then
        if [ "$enabled" == 'Y' ]; then
            return 0
        fi
    fi
    return 1
}

setup() {
    SYSLOG_EVENTS="-e sys_logger"

    if is_loaded; then
        echo "[Syslogger] Error: Already setup!"
    fi

    if lsmod | grep sys_logger &>/dev/null; then
        if [ "$verbose" = true ]; then
            echo "[Syslogger] Module ALREADY loaded"
        fi
    else
        $(insmod /system/lib/modules/sys_logger.ko $PARAMS)
        sleep 1
        if [ "$verbose" = true ]; then
            echo "[Syslogger] Module loaded"
        fi
    fi

    if [ "$verbose" = true ]; then
        echo "[Syslogger] insmod /system/lib/modules/sys_logger.ko $PARAMS"
    fi

    rm /data/local/tmp/trace.dat

    while [ ! -w /sys/module/sys_logger/parameters/enabled ]; do
        # Especially when switching to the interactive governor,
        # the sysfs is sometimes messed up. We have to try reloading
        # the module until it works. (happen also with other modules)
        rmmod /system/lib/modules/sys_logger
        sleep 3

        $(insmod /system/lib/modules/sys_logger.ko $PARAMS)
        ret=$?

        if [ "$ret" != 0 ]; then
            echo "[Syslogger] Error: Could not load kernel module"
            exit 1
        fi
        sleep 5
        if [ -w /sys/module/sys_logger/parameters/enabled ]; then
            break
        fi
    done

    printf "[Syslogger] Preparing to trace: "
    if [ "$trace_cg" == true ]; then
        APPEND="-e cpufreq_cg"
        printf "Chrome governor, "
    else
        APPEND=""
    fi

    if [ "$trace_binder" == true ]; then
        APPEND="${APPEND} -e binder_transaction -e cpu_idle -e sched_switch"
        printf "Binder, CPU idle, Context switches, "
    fi

    BUFFER_SIZE=20000
    if [ "$trace_threads" == true ]; then
        # in order to detect all chrome threads, we have to trace forks early
        APPEND="$APPEND -e sched:sched_process_fork"
        # We trace rougly 50mb per 30 second (mostly on little CPUs), make the
        # buffers big enough. 8 * 40 MB -> 320 MB
        BUFFER_SIZE=40000
        printf "Threads,  "
    fi

    if [ "$trace_opengl" == true ]; then
        SYSLOG_EVENTS="${SYSLOG_EVENTS} -e sys_logger:opengl_frame"
        printf "OpenGL, "
    fi

    printf "\n"

    # clear all events if enything is pending
    if [ "$verbose" = true ]; then
        echo "[Syslogger] Resetting"
        $MYDIR/trace-cmd reset
    else
        $MYDIR/trace-cmd reset >/dev/null
    fi

    # start tracing so we can monitor forks of children (relevant for chrome)
    echo "[Syslogger] Trace-cmd events: $SYSLOG_EVENTS"

    if [ ! $trace_record -eq false ]; then
        echo "[Syslogger] STARTING trace-cmd"
        $MYDIR/trace-cmd start \
            $SYSLOG_EVENTS \
            -i \
            -b $BUFFER_SIZE \
            -d -D \
            $APPEND
    else
        if [ "$verbose" = true ]; then
            echo "[Syslogger] $MYDIR/trace-cmd record $SYSLOG_EVENTS -i -o /data/local/tmp/trace.dat -d -D $APPEND"
        fi
        $MYDIR/trace-cmd record $SYSLOG_EVENTS -i -o /data/local/tmp/trace.dat -d -D $APPEND >/dev/null 2>&1 &

        echo "$(jobs -p)" >.trace.pid
        sleep 5

        echo "[Syslogger] RECORDING trace-cmd in background [$(jobs -p)], syslogger must still be enabled (started)"
    fi

    ret=$?
    if [ "$ret" != 0 ]; then
        echo "[Syslogger] Error: trace-cmd failed"
        rmmod /system/lib/modules/sys_logger
        exit 1
    fi
}

start() {
    if ! is_loaded; then
        echo "[Syslogger] Error: Not setup!"
        exit 1
    elif is_enabled; then
        echo "[Syslogger] Error: Already started!"
        exit 1
    fi

    # detect if we are tracing threads via active fork tracing
    tmp=$(cat /sys/kernel/debug/tracing/events/sched/sched_process_fork/enable 2>/dev/null)
    if [[ $tmp -eq "1" ]]; then
        # enable all expensive tracing
        echo 1 >/sys/kernel/debug/tracing/events/sched/sched_wakeup/enable
        echo 1 >/sys/kernel/debug/tracing/events/sched/sched_wakeup_new/enable
        echo 1 >/sys/kernel/debug/tracing/events/sched/sched_stat_runtime/enable
    fi

    # start a new measurement run
    # if [ ! $trace_record -eq true ]; then
    echo 1 >/sys/module/sys_logger/parameters/enabled
    if [ "$verbose" = true ]; then
        echo "[Syslogger] echo 1 > /sys/module/sys_logger/parameters/enabled"
    fi

    echo "[Syslogger] enabled"

    chmod 666 /dev/EGLSyslogger
}

stop() {
    if ! is_loaded; then
        echo "[Syslogger] Error: Not setup!"
        exit 1
    elif ! is_enabled; then
        echo "[Syslogger] Error: Not started!"
        exit 1
    fi

    # stop the measurement run
    echo 0 >/sys/module/sys_logger/parameters/enabled
    if [ "$verbose" = true ]; then
        echo "[Syslogger] echo 0 > /sys/module/sys_logger/parameters/enabled"
    fi

    echo "[Syslogger] disabled"

    # detect if we are tracing threads via active fork tracing
    tmp=$(cat /sys/kernel/debug/tracing/events/sched/sched_process_fork/enable 2>/dev/null)
    if [[ $tmp -eq "1" ]]; then
        # disable all expensive tracing
        echo 0 >/sys/kernel/debug/tracing/events/sched/sched_wakeup/enable
        echo 0 >/sys/kernel/debug/tracing/events/sched/sched_wakeup_new/enable
        echo 0 >/sys/kernel/debug/tracing/events/sched/sched_stat_runtime/enable
    fi
}

finish() {
    if ! is_loaded; then
        echo "Error: Not setup!"
        exit 1
    elif is_enabled; then
        stop
    fi

    if [ ! $trace_record -eq false ]; then
        # stop tracing
        $MYDIR/trace-cmd stop
        if [ "$verbose" = true ]; then
            echo "[Syslogger] $MYDIR/trace-cmd stop"
        fi

        # write the trace.dat file
        $MYDIR/trace-cmd extract -o $MYDIR/trace.dat
        if [ "$verbose" = true ]; then
            echo "[Syslogger] $MYDIR/trace-cmd extract -o $MYDIR/trace.dat"
        fi
    else
        while read x; do
            echo "[Syslogger] Killing [$x]"
            kill -INT $x
            wait
            sleep 5
        done <.trace.pid
    fi

    rm .trace.pid

    # turn of and reset all tracing
    $MYDIR/trace-cmd reset
    if [ "$verbose" = true ]; then
        echo "[Syslogger] $MYDIR/trace-cmd reset"
    fi

    if [ "$generate_report" == true ]; then
        echo "[Syslogger] Generating trace report"

        rm $MYDIR/*.report

        $MYDIR/trace-cmd report -i $MYDIR/trace.dat >$MYDIR/trace.report
        if [ "$verbose" = true ]; then
            echo "[Syslogger] $MYDIR/trace-cmd report -i $MYDIR/trace.dat > $MYDIR/trace.report"
        fi
        wait
    fi

    # unload the module
    rmmod /system/lib/modules/sys_logger.ko
    echo "[Syslogger] module unloaded"
}

if [ $# -lt 1 ]; then
    print_usage
    exit 1
fi

key="$1"
action=""

while [[ $# -gt 0 ]]; do
    key="$1"

    case $key in
    setup | start | stop | finish)
        action=$key
        shift # past argument
        ;;
    -cg | --chrome-governor)
        if [ "$action" != "setup" ]; then
            print_usage
            exit 1
        fi
        trace_cg=true
        shift # past argument
        ;;
    -nt | --no-threads)
        if [ "$action" != "setup" ]; then
            print_usage
            exit 1
        fi
        trace_threads=0
        shift # past argument
        ;;
    -nr | --no-report)
        if [ "$action" != "finish" ]; then
            print_usage
            exit 1
        fi
        generate_report=false
        shift
        ;;
    -nb | --no-binder)
        if [ "$action" != "setup" ]; then
            print_usage
            exit 1
        fi
        trace_binder=false
        shift
        ;;
    -nogl | --no-opengl)
        if [ "$action" != "setup" ]; then
            print_usage
            exit 1
        fi
        trace_opengl=false
        shift
        ;;
    -i)
        if [ "$action" != "setup" ]; then
            print_usage
            exit 1
        fi
        shift
        echo "interval set"
        default_interval=$1
        shift
        ;;
    -r | --record)
        trace_record=true
        shift
        ;;
    -v | --verbose)
        echo "[Syslogger] Running verbose"
        verbose=true
        shift
        ;;
    *)
        print_usage
        exit 1
        ;;
    esac
done

PARAMS="${PARAMS} interval=${default_interval}"

case "$action" in
setup)
    setup
    ;;
start)
    start
    ;;
stop)
    stop
    ;;
finish)
    finish
    ;;
*)
    print_usage
    exit 1
    ;;
esac

exit 0
