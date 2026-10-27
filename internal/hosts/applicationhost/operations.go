package applicationhost

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

type commandReceipt struct {
	Fingerprint string          `json:"fingerprint"`
	Result      json.RawMessage `json:"result"`
	CreatedAt   int64           `json:"createdAt"`
}

func stableID(commandID, key string) string {
	sum := sha256.Sum256([]byte(commandID + "\x00" + key))
	sum[6] = (sum[6] & 0x0f) | 0x50
	sum[8] = (sum[8] & 0x3f) | 0x80
	value := hex.EncodeToString(sum[:16])
	return value[:8] + "-" + value[8:12] + "-" + value[12:16] + "-" + value[16:20] + "-" + value[20:]
}
func fingerprint(pluginID, operationID string, input json.RawMessage) (string, error) {
	value, err := model.Decode(input)
	if err != nil {
		return "", err
	}
	normalized, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(append([]byte(pluginID+"\x00"+operationID+"\x00"), normalized...))
	return hex.EncodeToString(sum[:]), nil
}

func (h *Host) Query(ctx context.Context, request plugin.OperationRequest) (any, error) {
	return h.query(ctx, request, nil)
}
func (h *Host) query(ctx context.Context, request plugin.OperationRequest, owner *plugin.BackgroundAgentRef) (json.RawMessage, error) {
	if err := h.begin(); err != nil {
		return nil, err
	}
	defer h.operations.Done()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := h.application(request.PluginID); err != nil {
		return nil, err
	}
	background := owner != nil
	if background && owner.PluginID != request.PluginID {
		return nil, errors.New("background query owner mismatch")
	}
	snap := h.config.Store.Snapshot()
	reader := newReader(h, request.PluginID, snap)
	if definition, ok := h.queries[request.OperationID]; ok && definition.OwnerPluginID == request.PluginID {
		if (background && !definition.Audience.Background) || (!background && !definition.Audience.User) {
			return nil, errors.New("query audience denied")
		}
		input, err := definition.Input.Validate(request.Input)
		if err != nil {
			return nil, err
		}
		output, err := definition.Read(input, plugin.ReadContext{Owner: domainOwner(owner), Records: reader, Capabilities: h.snapshotCapabilities(snap, definition.Requires, reader.IssueScope)})
		if err != nil {
			return nil, err
		}
		return definition.Output.Validate(output)
	}
	if definition, ok := h.external[request.OperationID]; ok && definition.OwnerPluginID == request.PluginID {
		if (background && !definition.Audience.Background) || (!background && !definition.Audience.User) {
			return nil, errors.New("query audience denied")
		}
		input, err := definition.Input.Validate(request.Input)
		if err != nil {
			return nil, err
		}
		output, err := definition.Read(ctx, input, plugin.ExternalReadContext{Snapshot: plugin.ReadContext{Owner: domainOwner(owner), Records: reader, Capabilities: h.snapshotCapabilities(snap, definition.SnapshotRequires, reader.IssueScope)}, Capabilities: h.runtimeCapabilities(request.PluginID, definition.Requires)})
		if err != nil {
			return nil, err
		}
		return definition.Output.Validate(output)
	}
	return nil, fmt.Errorf("unknown application query: %s", request.OperationID)
}
func (h *Host) Command(ctx context.Context, request plugin.OperationRequest) (any, error) {
	return h.execute(ctx, request, nil, nil)
}
func (h *Host) execute(ctx context.Context, request plugin.OperationRequest, owner *plugin.BackgroundAgentRef, batch *plugin.BatchWriteContext) (json.RawMessage, error) {
	if err := h.begin(); err != nil {
		return nil, err
	}
	defer h.operations.Done()
	if err := h.application(request.PluginID); err != nil {
		return nil, err
	}
	if !validRecordID(request.RequestID) {
		return nil, errors.New("application command requires a stable request ID")
	}
	definition, ok := h.commands[request.OperationID]
	if !ok || definition.OwnerPluginID != request.PluginID {
		return nil, fmt.Errorf("unknown application command: %s", request.OperationID)
	}
	source := request.PluginID
	if owner == nil {
		if !definition.Audience.User || batch != nil {
			return nil, errors.New("command audience denied")
		}
	} else {
		source = owner.AgentID
		if owner.PluginID != request.PluginID || definition.Audience.Background == "deny" || (definition.Audience.Background == "batch-required" && batch == nil) {
			return nil, errors.New("background command audience denied")
		}
	}
	input, err := definition.Input.Validate(request.Input)
	if err != nil {
		return nil, err
	}
	identity, err := fingerprint(request.PluginID, request.OperationID, input)
	if err != nil {
		return nil, err
	}
	committedAt := h.config.Now().UnixMilli()
	commandID := source + ":" + request.RequestID
	if batch != nil {
		prefix := owner.AgentID + "."
		if len(batch.ConsumerID) <= len(prefix) || batch.ConsumerID[:len(prefix)] != prefix {
			return nil, errors.New("batch belongs to another background agent")
		}
		if !validRecordID(batch.InvocationID) {
			return nil, errors.New("invalid batch invocation ID")
		}
		commandID = batch.ConsumerID + ":" + batch.BatchID + ":" + batch.InvocationID
	}
	var result json.RawMessage
	_, err = h.config.Store.Update(ctx, func(tx *store.Tx) error {
		receiptKey := "application-command-receipt:" + source + ":" + stableID(commandID, request.RequestID)
		if batch != nil {
			work, exists, e := tx.Work(batch.ConsumerID)
			if e != nil {
				return e
			}
			if !exists || work.ID != batch.BatchID {
				return errors.New("background batch is no longer active")
			}
		}
		var previous commandReceipt
		hasPrevious, e := tx.Get(receiptKey, &previous)
		if e != nil {
			return e
		}
		if hasPrevious {
			if previous.Fingerprint != identity {
				return errors.New("application request ID reused with different input")
			}
			result = model.CloneRaw(previous.Result)
			return nil
		}
		var batchReceipt *store.Receipt
		if batch != nil {
			batchReceipt = &store.Receipt{ConsumerID: batch.ConsumerID, BatchID: batch.BatchID, Key: stableID(request.OperationID, batch.InvocationID)}
			raw, found, e := tx.ReadReceipt(*batchReceipt)
			if e != nil {
				return e
			}
			if found {
				var old commandReceipt
				if e = json.Unmarshal(raw, &old); e != nil {
					return e
				}
				if old.Fingerprint != identity {
					return errors.New("batch invocation reused with different input")
				}
				result = model.CloneRaw(old.Result)
				return nil
			}
		}
		snap := tx.Snapshot()
		reader := newReader(h, request.PluginID, snap)
		scopes, e := definition.Plan(input, plugin.ReadContext{Owner: domainOwner(owner), Records: reader, Capabilities: h.snapshotCapabilities(snap, definition.Requires, reader.IssueScope)})
		if e != nil {
			return e
		}
		allowed := map[string]plugin.MutationScope{}
		for _, scope := range scopes {
			issued, ok := reader.issued[scope.Token()]
			if !ok || issued != scope {
				return errors.New("command returned an unissued mutation scope")
			}
			allowed[scope.Collection()] = scope
		}
		reader.allowed = allowed
		for key := range reader.readKeys {
			if !reader.covered(key) {
				return fmt.Errorf("command plan omitted read dependency %s", key)
			}
		}
		reader.tx = tx
		reader.committedAt = committedAt
		reader.commandID = commandID
		reader.source = source
		output, e := definition.Reduce(model.CloneRaw(input), plugin.TransactionContext{Owner: domainOwner(owner), Records: reader, Capabilities: h.snapshotCapabilities(snap, definition.Requires, reader.IssueScope), CommandID: commandID, CommittedAt: committedAt, AllocateID: func(localKey string) string { return stableID(commandID, localKey) }})
		if e != nil {
			return e
		}
		output, e = definition.Output.Validate(output)
		if e != nil {
			return e
		}
		if e = reader.flushEvents(); e != nil {
			return e
		}
		receipt := commandReceipt{Fingerprint: identity, Result: output, CreatedAt: committedAt}
		if batchReceipt != nil {
			if e = tx.RecordReceipt(*batchReceipt, receipt); e != nil {
				return e
			}
		}
		if e = tx.Put(receiptKey, receipt); e != nil {
			return e
		}
		result = model.CloneRaw(output)
		return nil
	})
	return result, err
}

type domainClient struct {
	host  *Host
	owner plugin.BackgroundAgentRef
}

func (d domainClient) Query(ctx context.Context, id string, input json.RawMessage) (json.RawMessage, error) {
	return d.host.query(ctx, plugin.OperationRequest{PluginID: d.owner.PluginID, OperationID: id, Input: input}, &d.owner)
}
func (d domainClient) Execute(ctx context.Context, id string, input json.RawMessage, options plugin.DomainCommandOptions) (json.RawMessage, error) {
	return d.host.execute(ctx, plugin.OperationRequest{PluginID: d.owner.PluginID, OperationID: id, Input: input, RequestID: options.RequestID}, &d.owner, options.Batch)
}

// Copy the trusted caller identity so callbacks cannot mutate the client owner.
func domainOwner(owner *plugin.BackgroundAgentRef) plugin.BackgroundAgentRef {
	if owner == nil {
		return plugin.BackgroundAgentRef{}
	}
	return *owner
}
