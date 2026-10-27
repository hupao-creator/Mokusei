package main

import "testing"

func TestFinalOwnerGCEvidenceIsRequired(t *testing.T) {
	log := []byte("gc old\n{\"pid\":1,\"epoch\":\"old\",\"status\":\"running\"}\ngc old again\n{\"pid\":2,\"epoch\":\"new\",\"status\":\"running\"}\ngc current\n")
	got, e := finalOwnerGCLog(log, 2, "new")
	if e != nil || string(got) != "gc current\n" {
		t.Fatalf("wrong generation: %q %v", got, e)
	}
	if _, e = finalOwnerGCLog(log, 2, "old"); e == nil {
		t.Fatal("mixed old epoch with new PID")
	}
	if _, e = finalOwnerGCLog([]byte("gc 1 @1s 4->4->2 MB"), 2, "new"); e == nil {
		t.Fatal("accepted absent owner evidence")
	}
}

func TestGCHeapEvidenceAndGrowth(t *testing.T) {
	values := parseGCHeap([]byte("gc 23 @2.712s 1%: 0.02+0.1+0.03 ms clock, 4->5->3 MB, 6 MB goal, 0 MB stacks, 0 MB globals, 12 P\nnot a GC line\ngc 24 @3.5s 1%: 0.02+0.1+0.03 ms clock, 5->6->4 MB, 8 MB goal\n"))
	if len(values) != 2 || values[0] != 3 || values[1] != 4 {
		t.Fatalf("GC evidence=%v", values)
	}
	if verifyGCHeap(values) == nil {
		t.Fatal("insufficient GC evidence accepted")
	}
	samples := make([]int, 20)
	for i := range samples {
		samples[i] = 3
	}
	if e := verifyGCHeap(samples); e != nil {
		t.Fatal(e)
	}
	samples[15] = 36
	if verifyGCHeap(samples) == nil {
		t.Fatal("live heap growth accepted")
	}
}

func TestOwnedProcessIdentityRejectsPIDReuse(t *testing.T) {
	want := processSample{PID: 123, PGID: 123, Started: "Sat Oct 24 08:00:00 2026", Command: "/fixture/codex"}
	if !sameProcess(want, want) {
		t.Fatal("lost known process")
	}
	for _, field := range []string{"pid", "group", "birth", "command"} {
		actual := want
		switch field {
		case "pid":
			actual.PID++
		case "group":
			actual.PGID++
		case "birth":
			actual.Started = "Sat Oct 24 08:00:01 2026"
		case "command":
			actual.Command = "/unrelated/process"
		}
		if sameProcess(want, actual) {
			t.Fatalf("accepted changed %s", field)
		}
	}
	want.Started = ""
	if sameProcess(want, want) {
		t.Fatal("accepted missing process identity")
	}
}

func TestResourceGateRejectsGrowthAndResidualChildren(t *testing.T) {
	makeSamples := func() []resourceSample {
		s := make([]resourceSample, 25)
		for i := range s {
			s[i] = resourceSample{Cycle: i + 1, RSSKiB: 100 * 1024, FDs: 20}
		}
		return s
	}
	if e := verifyResources(makeSamples()); e != nil {
		t.Fatal(e)
	}
	for _, metric := range []string{"rss", "fd", "child", "spike"} {
		t.Run(metric, func(t *testing.T) {
			s := makeSamples()
			switch metric {
			case "rss":
				for i := 20; i < 25; i++ {
					s[i].RSSKiB += 65 * 1024
				}
			case "fd":
				for i := 20; i < 25; i++ {
					s[i].FDs += 9
				}
			case "child":
				s[20].Descendants = 1
			case "spike":
				s[12].RSSKiB += 65 * 1024
			}
			if verifyResources(s) == nil {
				t.Fatalf("accepted %s regression", metric)
			}
		})
	}
	if verifyResources(makeSamples()[:14]) == nil {
		t.Fatal("accepted insufficient samples")
	}
}
