// _fc_agent — vsock listener for Firecracker snapshot command delivery.
//
// Listens on AF_VSOCK port 52000, accepts one connection from the host,
// reads one line (the base64-encoded command), prints it to stdout, and exits.
//
// Used by _fc_init.sh in snapshot mode:
//
//	/_fc_agent > /tmp/fc_cmd_b64 &
//	FC_AGENT_PID=$!
//	sleep 0.2      # ensure Accept() is reached before snapshot
//	echo "===FC_READY==="
//	wait $FC_AGENT_PID
//	CMD_B64=$(cat /tmp/fc_cmd_b64)
//
// The host side sends the command via the Firecracker vsock UDS proxy:
//
//	CONNECT 52000\n  →  OK 52000\n  →  <base64cmd>\n
package main

import (
	"bufio"
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

const (
	// afVSOCK is the Linux AF_VSOCK address family (40 on all architectures).
	afVSOCK = 40

	// vmaddrCIDAny accepts connections from any CID (0xFFFFFFFF = VMADDR_CID_ANY).
	vmaddrCIDAny = 0xFFFFFFFF

	// vsockPort is the port the agent listens on.
	vsockPort = 52000
)

// sockaddrVM is the Linux sockaddr_vm structure (AF_VSOCK).
// Must match the kernel ABI: 16 bytes total on all supported architectures.
//
//	struct sockaddr_vm {
//	    sa_family_t    svm_family;    // 2 bytes
//	    unsigned short svm_reserved1; // 2 bytes
//	    unsigned int   svm_port;      // 4 bytes
//	    unsigned int   svm_cid;       // 4 bytes
//	    unsigned char  svm_zero[4];   // 4 bytes padding to reach 16
//	};
type sockaddrVM struct {
	Family    uint16
	Reserved1 uint16
	Port      uint32
	CID       uint32
	Zero      [4]byte
}

func main() {
	fd, err := syscall.Socket(afVSOCK, syscall.SOCK_STREAM, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "_fc_agent: socket: %v\n", err)
		os.Exit(1)
	}
	defer syscall.Close(fd)

	sa := sockaddrVM{
		Family: afVSOCK,
		Port:   vsockPort,
		CID:    vmaddrCIDAny,
	}
	_, _, errno := syscall.Syscall(
		syscall.SYS_BIND,
		uintptr(fd),
		uintptr(unsafe.Pointer(&sa)),
		unsafe.Sizeof(sa),
	)
	if errno != 0 {
		fmt.Fprintf(os.Stderr, "_fc_agent: bind: %v\n", errno)
		os.Exit(1)
	}

	if err := syscall.Listen(fd, 1); err != nil {
		fmt.Fprintf(os.Stderr, "_fc_agent: listen: %v\n", err)
		os.Exit(1)
	}

	// Accept exactly one connection. The snapshot is taken while we are
	// blocked here; on restore we resume and accept the host connection.
	connFd, _, err := syscall.Accept(fd)
	if err != nil {
		fmt.Fprintf(os.Stderr, "_fc_agent: accept: %v\n", err)
		os.Exit(1)
	}
	defer syscall.Close(connFd)

	conn := os.NewFile(uintptr(connFd), "vsock")
	scanner := bufio.NewScanner(conn)
	if scanner.Scan() {
		// Print the base64 command to stdout for the init script to capture.
		fmt.Println(scanner.Text())
	}
	if err := scanner.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "_fc_agent: read: %v\n", err)
		os.Exit(1)
	}
}
