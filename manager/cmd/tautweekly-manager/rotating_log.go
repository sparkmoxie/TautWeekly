package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

const managerLogMaximumBytes int64 = 1 << 20
const managerLogBackups = 3

type rotatingLogWriter struct {
	mu      sync.Mutex
	path    string
	maximum int64
	backups int
	file    *os.File
	closed  bool
}

func newRotatingLogWriter(path string, maximum int64, backups int) (*rotatingLogWriter, error) {
	if !filepath.IsAbs(path) || maximum < 1 || backups < 1 {
		return nil, errors.New("bounded log requires an absolute path and positive limits")
	}
	parent, err := os.Lstat(filepath.Dir(path))
	if err != nil || !parent.IsDir() || parent.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("bounded log directory must be an existing directory, not a link")
	}
	w := &rotatingLogWriter{path: filepath.Clean(path), maximum: maximum, backups: backups}
	if err := w.prepareBackups(); err != nil {
		return nil, err
	}
	if err := w.open(); err != nil {
		return nil, err
	}
	return w, nil
}

func regularLogInfo(path string) (os.FileInfo, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("bounded log refuses links and nonregular files")
	}
	return info, nil
}

// Open without truncation, then verify the opened object still names the same
// regular file before changing permissions, bytes, or length.
func openRegularLog(path string) (*os.File, error) {
	before, err := regularLogInfo(path)
	if err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	opened, openErr := file.Stat()
	after, pathErr := regularLogInfo(path)
	if openErr != nil || pathErr != nil || after == nil || !opened.Mode().IsRegular() || !os.SameFile(opened, after) || before != nil && !os.SameFile(before, opened) {
		_ = file.Close()
		return nil, errors.New("bounded log file changed while opening")
	}
	if linked, err := logFileHasMultipleLinks(file); err != nil || linked {
		_ = file.Close()
		return nil, errors.New("bounded log refuses hard links")
	}
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		return nil, err
	}
	return file, nil
}

func boundLogTail(file *os.File, maximum int64) error {
	info, err := file.Stat()
	if err != nil || info.Size() <= maximum {
		return err
	}
	tail := make([]byte, maximum)
	if _, err := file.ReadAt(tail, info.Size()-maximum); err != nil {
		return err
	}
	if err := file.Truncate(0); err != nil {
		return err
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return err
	}
	_, err = file.Write(tail)
	return err
}

func (w *rotatingLogWriter) prepareBackups() error {
	entries, err := os.ReadDir(filepath.Dir(w.path))
	if err != nil {
		return err
	}
	prefix := filepath.Base(w.path) + "."
	for _, entry := range entries {
		suffix, owned := strings.CutPrefix(entry.Name(), prefix)
		if !owned || suffix == "" || suffix[0] == '0' || strings.Trim(suffix, "0123456789") != "" {
			continue
		}
		path := filepath.Join(filepath.Dir(w.path), entry.Name())
		if _, err := regularLogInfo(path); err != nil {
			return err
		}
		number, parseErr := strconv.Atoi(suffix)
		if parseErr != nil || number > w.backups {
			if err := os.Remove(path); err != nil {
				return err
			}
			continue
		}
		file, err := openRegularLog(path)
		if err != nil {
			return err
		}
		err = boundLogTail(file, w.maximum)
		closeErr := file.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
	}
	return nil
}

func (w *rotatingLogWriter) open() error {
	file, err := openRegularLog(w.path)
	if err != nil {
		return err
	}
	if err := boundLogTail(file, w.maximum); err != nil {
		_ = file.Close()
		return err
	}
	w.file = file
	return nil
}

func (w *rotatingLogWriter) rotate() error {
	if w.file != nil {
		_ = w.file.Close()
		w.file = nil
	}
	// Check every exact owned path before rotating so a link is never followed.
	for index := 0; index <= w.backups; index++ {
		path := w.path
		if index > 0 {
			path += "." + strconv.Itoa(index)
		}
		if _, err := regularLogInfo(path); err != nil {
			return err
		}
	}
	for index := w.backups; index > 0; index-- {
		destination := w.path + "." + strconv.Itoa(index)
		if err := os.Remove(destination); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		source := w.path
		if index > 1 {
			source += "." + strconv.Itoa(index-1)
		}
		if err := os.Rename(source, destination); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return w.open()
}

func (w *rotatingLogWriter) Write(data []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return 0, os.ErrClosed
	}
	if w.file == nil {
		if err := w.open(); err != nil {
			return 0, err
		}
	}
	opened, err := w.file.Stat()
	if err != nil {
		return 0, err
	}
	named, err := regularLogInfo(w.path)
	if err != nil {
		return 0, err
	}
	if named == nil || !os.SameFile(opened, named) {
		_ = w.file.Close()
		w.file = nil
		if err := w.open(); err != nil {
			return 0, err
		}
	}
	written := 0
	for len(data) > 0 {
		info, err := w.file.Stat()
		if err != nil {
			return written, err
		}
		if info.Size() >= w.maximum {
			if err := w.rotate(); err != nil {
				return written, fmt.Errorf("rotate bounded log: %w", err)
			}
			continue
		}
		length := min(int64(len(data)), w.maximum-info.Size())
		if _, err := w.file.Seek(0, io.SeekEnd); err != nil {
			return written, err
		}
		count, err := w.file.Write(data[:length])
		written += count
		data = data[count:]
		if err != nil {
			return written, err
		}
		if int64(count) != length {
			return written, io.ErrShortWrite
		}
	}
	return written, nil
}

func (w *rotatingLogWriter) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.closed = true
	if w.file != nil {
		return w.file.Close()
	}
	return nil
}
