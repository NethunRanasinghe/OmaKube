package main

import "time"

// secondsToDuration keeps timeout plumbing in one place.
func secondsToDuration(sec int) time.Duration {
	if sec <= 0 {
		sec = 8
	}
	return time.Duration(sec) * time.Second
}
