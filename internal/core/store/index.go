package store

import (
	"slices"
	"sort"
	"strings"
)

// indexNode is a persistent compressed radix tree. Values must be nonzero.
// Updates copy only the branch leading to a key; snapshots share untouched
// nodes. Full prefixes keep branch identity stable across splits and merges,
// which also lets a diff skip shared subtrees without enumerating their keys.
type indexNode[V comparable] struct {
	prefix   string
	value    V
	count    int
	children []*indexNode[V]
}

func indexGet[V comparable](root *indexNode[V], key string) (V, bool) {
	var zero V
	for root != nil && strings.HasPrefix(key, root.prefix) {
		if len(key) == len(root.prefix) {
			return root.value, root.value != zero
		}
		i, found := indexChild(root, key[len(root.prefix)])
		if !found {
			break
		}
		root = root.children[i]
	}
	return zero, false
}

func indexChild[V comparable](root *indexNode[V], next byte) (int, bool) {
	position := len(root.prefix)
	i := sort.Search(len(root.children), func(i int) bool { return root.children[i].prefix[position] >= next })
	return i, i < len(root.children) && root.children[i].prefix[position] == next
}

func indexSet[V comparable](root *indexNode[V], key string, value V) *indexNode[V] {
	if root == nil {
		return &indexNode[V]{prefix: key, value: value, count: 1}
	}
	common := 0
	for common < len(root.prefix) && common < len(key) && root.prefix[common] == key[common] {
		common++
	}
	if common < len(root.prefix) {
		parent := &indexNode[V]{prefix: key[:common], count: root.count + 1, children: []*indexNode[V]{root}}
		if common == len(key) {
			parent.value = value
		} else {
			leaf := &indexNode[V]{prefix: key, value: value, count: 1}
			if key[common] < root.prefix[common] {
				parent.children = []*indexNode[V]{leaf, root}
			} else {
				parent.children = []*indexNode[V]{root, leaf}
			}
		}
		return parent
	}
	if common == len(key) && root.value == value {
		return root
	}
	copy := *root
	if common == len(key) {
		var zero V
		if copy.value == zero {
			copy.count++
		}
		copy.value = value
		return &copy
	}
	i, found := indexChild(root, key[common])
	copy.children = slices.Clone(root.children)
	if found {
		copy.children[i] = indexSet(root.children[i], key, value)
		copy.count += copy.children[i].count - root.children[i].count
	} else {
		copy.children = slices.Insert(copy.children, i, &indexNode[V]{prefix: key, value: value, count: 1})
		copy.count++
	}
	return &copy
}

func indexDelete[V comparable](root *indexNode[V], key string) *indexNode[V] {
	var zero V
	if root == nil || !strings.HasPrefix(key, root.prefix) {
		return root
	}
	copy := *root
	if len(key) == len(root.prefix) {
		if root.value == zero {
			return root
		}
		copy.value = zero
		copy.count--
	} else {
		i, found := indexChild(root, key[len(root.prefix)])
		if !found {
			return root
		}
		child := indexDelete(root.children[i], key)
		if child == root.children[i] {
			return root
		}
		copy.children = slices.Clone(root.children)
		copy.count -= root.children[i].count
		if child == nil {
			copy.children = slices.Delete(copy.children, i, i+1)
		} else {
			copy.children[i] = child
			copy.count += child.count
		}
	}
	if copy.value == zero {
		if len(copy.children) == 0 {
			return nil
		}
		if len(copy.children) == 1 {
			return copy.children[0]
		}
	}
	return &copy
}

func indexPrefix[V comparable](root *indexNode[V], prefix string) *indexNode[V] {
	for root != nil {
		if strings.HasPrefix(root.prefix, prefix) {
			return root
		}
		if !strings.HasPrefix(prefix, root.prefix) {
			return nil
		}
		i, found := indexChild(root, prefix[len(root.prefix)])
		if !found {
			return nil
		}
		root = root.children[i]
	}
	return nil
}

func indexWalk[V comparable](root *indexNode[V], visit func(string, V) bool) bool {
	var zero V
	if root == nil {
		return true
	}
	if root.value != zero && !visit(root.prefix, root.value) {
		return false
	}
	for _, child := range root.children {
		if !indexWalk(child, visit) {
			return false
		}
	}
	return true
}

// indexDiff visits changes in key order. A zero value denotes an absent key.
func indexDiff[V comparable](before, after *indexNode[V], visit func(string, V, V) bool) bool {
	var zero V
	if before == after {
		return true
	}
	if before == nil {
		return indexWalk(after, func(key string, value V) bool { return visit(key, zero, value) })
	}
	if after == nil {
		return indexWalk(before, func(key string, value V) bool { return visit(key, value, zero) })
	}
	if before.prefix == after.prefix {
		if before.value != after.value && !visit(before.prefix, before.value, after.value) {
			return false
		}
		i, j := 0, 0
		for i < len(before.children) || j < len(after.children) {
			if j == len(after.children) || (i < len(before.children) && before.children[i].prefix[len(before.prefix)] < after.children[j].prefix[len(after.prefix)]) {
				if !indexDiff(before.children[i], nil, visit) {
					return false
				}
				i++
			} else if i == len(before.children) || before.children[i].prefix[len(before.prefix)] > after.children[j].prefix[len(after.prefix)] {
				if !indexDiff(nil, after.children[j], visit) {
					return false
				}
				j++
			} else {
				if !indexDiff(before.children[i], after.children[j], visit) {
					return false
				}
				i++
				j++
			}
		}
		return true
	}
	if strings.HasPrefix(after.prefix, before.prefix) {
		if before.value != zero && !visit(before.prefix, before.value, zero) {
			return false
		}
		next := after.prefix[len(before.prefix)]
		matched := false
		for _, child := range before.children {
			if !matched && child.prefix[len(before.prefix)] > next {
				if !indexDiff(nil, after, visit) {
					return false
				}
				matched = true
			}
			var current *indexNode[V]
			if child.prefix[len(before.prefix)] == next {
				current, matched = after, true
			}
			if !indexDiff(child, current, visit) {
				return false
			}
		}
		return matched || indexDiff(nil, after, visit)
	}
	if strings.HasPrefix(before.prefix, after.prefix) {
		return indexDiff(after, before, func(key string, previous, current V) bool { return visit(key, current, previous) })
	}
	if before.prefix < after.prefix {
		return indexDiff(before, nil, visit) && indexDiff(nil, after, visit)
	}
	return indexDiff(nil, after, visit) && indexDiff(before, nil, visit)
}
