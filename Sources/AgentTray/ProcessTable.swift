import AgentTrayCore
import Darwin
import Foundation

/// Reads all processes from the kernel. Arguments and the working directory are read only
/// for `ssh` (Speedwave windows); the rest are needed for local sessions' pids and for
/// walking up to the terminal app. Other users' processes are needed too: terminals start
/// the shell through `/usr/bin/login`, which runs as root.
enum ProcessTable {
    static func read() -> [HostProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // Room for processes started between the two calls.
        var infos = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = infos.count * stride
        guard sysctl(&mib, u_int(mib.count), &infos, &size, nil, 0) == 0 else { return [] }

        return infos.prefix(size / stride).map { info in
            let pid = info.kp_proc.p_pid
            let started = info.kp_proc.p_un.__p_starttime
            let detailed = command(info) == "ssh"
            return HostProcess(
                pid: pid,
                parentPid: info.kp_eproc.e_ppid,
                startTime: Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000),
                tty: tty(info.kp_eproc.e_tdev),
                arguments: detailed ? arguments(of: pid) : [],
                workingDirectory: detailed ? workingDirectory(of: pid) : nil
            )
        }
    }

    private static func command(_ info: kinfo_proc) -> String {
        withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func tty(_ device: dev_t) -> String? {
        guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
        let text = String(cString: name)
        return text.isEmpty || text == "??" ? nil : "/dev/" + text
    }

    /// `KERN_PROCARGS2`: argc, the executable path, padding, then argv as C strings.
    private static func arguments(of pid: pid_t) -> [String] {
        var argmaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        guard sysctl(&argmaxMib, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return [] }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }

        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var result: [String] = []
        var start = index
        while index < size, result.count < argc {
            if buffer[index] == 0 {
                result.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return result
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }
}
