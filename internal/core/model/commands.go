package model

// commandReadOnly is the protocol registry, independent of installed plugins.
var commandReadOnly = map[string]bool{
	"search:status": true, "search:query": true, "search:configure": false, "search:index": false, "search:model": false,
	"attachment:preview": true, "attachment:discard": false,
	"moku:voice": false, "moku:voice-events": true, "thread:voice": false, "thread:voice-events": true,
	"moku:deliveries": true, "moku:resolve-delivery": false,
	"moku:submit": false, "moku:clear": false, "moku:stage-attachments": false, "moku:cancel": false,
	"moku:record-note-exposure": false,
	"history:clear":             false, "thread:follow-up": false, "thread:interrupt": false,
	"thread:interaction-respond": false, "thread:read": true, "thread:fork": false,
	"thread:update-settings": false, "app:update-settings": false, "settings:diagnostics": true,
	"harness:detect-installations": false, "harness:detect-installation": true, "workspace:list-known-directories": true,
	"harness:install": false, "harness:settings-presentation": true, "harness:extension": false,
	"thread:set-archived": false, "application:archive": false, "application:initialize-conversation": false,
	"application:command": false, "state:load": true, "application:query": true,
}

func IsCommandChannel(channel string) bool  { _, ok := commandReadOnly[channel]; return ok }
func IsReadOnlyChannel(channel string) bool { return commandReadOnly[channel] }
