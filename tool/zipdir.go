// 把目录打成 zip：给 CI 产 Windows 包用。
//
// 为什么不用现成工具：
//   - `Compress-Archive`（PowerShell 5.1）写出来的条目用反斜杠做分隔符，
//     `unzip` 直接报 “appears to use backslashes as path separators” 并失败；
//     用 `Get-ChildItem | Compress-Archive` 还会把一级目录摊平，
//     解压出来 bin\ 和 data\ 全跑到根目录 —— 包看着正常，程序起不来。
//   - Git for Windows 不带 `zip`。
//   - 走 PowerShell 步骤时 runner 用 UTF-8 落盘脚本、PS 5.1 按 ANSI 解码，
//     脚本里的中文注释会让引号配对错位（报错信息还完全不相干）。
//
// 因此用 Go 标准库：输出符合 zip 规范的 `/` 分隔路径，任何解压工具都能正确还原，
// 也和 pipeline 引擎一样只依赖标准库、不需要 go.mod（GO111MODULE=off 直接跑单文件）。
//
// 用法：
//   go run tool/zipdir.go <源目录> <目标.zip> [要跳过的名字...]
// 例：
//   go run tool/zipdir.go build/windows/x64/runner/Release dist/cytest-windows-x64.zip cytest.exe.WebView2
package main

import (
	"archive/zip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "用法: zipdir <源目录> <目标.zip> [要跳过的名字...]")
		os.Exit(2)
	}
	src, dst := os.Args[1], os.Args[2]
	skip := map[string]bool{}
	for _, n := range os.Args[3:] {
		skip[n] = true
	}

	if _, err := os.Stat(src); err != nil {
		fmt.Fprintf(os.Stderr, "源目录不存在: %v\n", err)
		os.Exit(1)
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "创建输出目录失败: %v\n", err)
		os.Exit(1)
	}

	out, err := os.Create(dst)
	if err != nil {
		fmt.Fprintf(os.Stderr, "创建 zip 失败: %v\n", err)
		os.Exit(1)
	}
	defer out.Close()

	zw := zip.NewWriter(out)
	files := 0
	walkErr := filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, p)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		// 跳过指定名字（目录整棵剪掉，文件单独跳过）
		for _, seg := range strings.Split(filepath.ToSlash(rel), "/") {
			if skip[seg] {
				if info.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
		}
		if info.IsDir() {
			return nil // 目录条目不是必需，工具会按文件路径自动建目录
		}
		if !info.Mode().IsRegular() {
			return nil
		}

		hdr, err := zip.FileInfoHeader(info)
		if err != nil {
			return err
		}
		// 规范要求 `/`；Deflate 对 Dart AOT 的产物压得比 Store 好不少
		hdr.Name = filepath.ToSlash(rel)
		hdr.Method = zip.Deflate
		w, err := zw.CreateHeader(hdr)
		if err != nil {
			return err
		}
		f, err := os.Open(p)
		if err != nil {
			return err
		}
		defer f.Close()
		if _, err := io.Copy(w, f); err != nil {
			return err
		}
		files++
		return nil
	})

	// 先把 walk 的错误收掉，再关 writer：顺序反了会把「写失败」误报成 walk 失败
	if walkErr != nil {
		fmt.Fprintf(os.Stderr, "遍历源目录失败: %v\n", walkErr)
		os.Exit(1)
	}
	if err := zw.Close(); err != nil {
		fmt.Fprintf(os.Stderr, "写入 zip 失败: %v\n", err)
		os.Exit(1)
	}
	if files == 0 {
		fmt.Fprintln(os.Stderr, "一个文件都没打进去，源目录是空的？")
		os.Exit(1)
	}

	st, err := os.Stat(dst)
	if err != nil {
		fmt.Fprintf(os.Stderr, "读不到产物: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("打包完成: %s  %d 个文件  %.1f MiB\n", dst, files, float64(st.Size())/(1<<20))
}
