package main

import (
	"path/filepath"
	"reflect"
	"testing"
)

func TestBuildDaemonArgs(t *testing.T) {
	initVideo := "/tmp/clip.mp4"
	absRel := func(p string) string {
		abs, err := filepath.Abs(p)
		if err != nil {
			t.Fatal(err)
		}
		return abs
	}

	tests := []struct {
		name string
		in   []string
		want []string
	}{
		{
			// 回归：--dir 必须保留给子进程以重建播放列表，不能被剥离成单个 --video
			name: "目录模式：--dir 保留为绝对路径并注入初始视频",
			in:   []string{"--dir", "videos"},
			want: []string{"--dir", absRel("videos"), "--video", initVideo, "--daemon"},
		},
		{
			name: "目录模式 --dir= 写法",
			in:   []string{"--dir=videos", "--mute"},
			want: []string{"--dir=" + absRel("videos"), "--mute", "--video", initVideo, "--daemon"},
		},
		{
			name: "显式 --video：保留原值不注入",
			in:   []string{"--video", "/a/b.mp4"},
			want: []string{"--video", "/a/b.mp4", "--daemon"},
		},
		{
			name: "video 与 dir 并存：都保留",
			in:   []string{"--video", "/a/b.mp4", "--dir", "videos"},
			want: []string{"--video", "/a/b.mp4", "--dir", absRel("videos"), "--daemon"},
		},
		{
			name: "已有 --daemon 不重复追加",
			in:   []string{"--video", "/a/b.mp4", "--daemon"},
			want: []string{"--video", "/a/b.mp4", "--daemon"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := buildDaemonArgs(tt.in, initVideo)
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("got %v, want %v", got, tt.want)
			}
		})
	}
}
