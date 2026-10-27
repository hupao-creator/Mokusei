# Native Lucide paths

The native icon catalog is derived from the exact installed `lucide-react@0.544.0`
package used by the Electron renderer, under `dist/esm/icons/*.js`. The upstream
[Lucide project](https://github.com/lucide-icons/lucide) uses ISC (with Feather
portions under MIT); the complete package license is included as `lucide-LICENSE.txt`.

The catalog contains every Lucide name imported by the desktop renderer and current
plugin renderers, plus common navigation/control icons. It has 136 source names and
141 normalized lookup keys (React aliases and canonical SVG names share geometry).

`NativeIcon` accepts PascalCase and kebab-case names. It renders native SwiftUI Paths
and AppKit template images; it does not use SVG WebViews or SF Symbol substitutions.
Unknown names produce a crossed-square placeholder and an explicit accessibility label.

## Geometry conversion

`lucide-paths.json` stores the original 24 × 24 SVG geometry in normalized commands:
`M`/`L`/`C`/`Q`/`Z` for paths; `E` for ellipse rectangles; `R` for rounded rectangles;
`A` for center, radii, rotation, start angle and sweep angle. Original SVG path data
was parsed with the Python `svg.path` package. Relative commands and smooth controls
were expanded; SVG endpoint arcs were converted to center parameterization and are
drawn analytically with `Path.addRelativeArc`, rather than polygon approximation.
Values retain ten decimal places. Stroke width remains in SVG viewBox units; stroke
caps and joins are round, matching Lucide. `key` fields from React are omitted.

The conversion covers each source node type (`path`, `line`, `polyline`, `polygon`,
`circle`, `ellipse`, `rect`) without changing its outline. There are no source transforms,
custom fill attributes, or node-level stroke overrides in this selected catalog.

Temporary native rendering probes verified all catalog entries and produced a contact
sheet for visual review. These probes are intentionally not part of the unit-test suite.

## Source icon names

Activity, AlertCircle, Archive, ArchiveRestore, ArrowDown, ArrowDownLeft, ArrowDownRight, ArrowLeft, ArrowRight, ArrowUp, ArrowUpLeft, ArrowUpRight, AudioLines, Bell, BookOpen, Bot, Check, CheckCheck, CheckCircle2, ChevronDown, ChevronLeft, ChevronRight, ChevronUp, ChevronsLeft, ChevronsRight, Circle, CircleAlert, CircleCheck, CircleDashed, CircleHelp, CircleStop, CircleX, Clipboard, Clock, Code, CodeXml, Combine, Copy, CornerDownRight, Download, Ellipsis, EllipsisVertical, ExternalLink, Eye, EyeOff, File, FileCode, FileDiff, FileImage, FilePenLine, FilePlus, FileQuestion, FileText, Folder, FolderClosed, FolderOpen, FolderPlus, GitBranch, GitCommitHorizontal, GitFork, GitPullRequest, Globe, Globe2, Grip, GripVertical, Hash, History, Home, Hourglass, Image, Info, Layers, Link, List, ListChecks, ListFilter, ListTodo, LoaderCircle, Lock, LogOut, Maximize2, Menu, MessageCircle, MessageSquare, MessageSquarePlus, Mic, MicOff, Minimize2, Minus, Monitor, Moon, MoreHorizontal, MoreVertical, Move, PanelLeft, PanelLeftClose, PanelLeftOpen, PanelRight, Paperclip, Pause, PenLine, Pencil, Phone, PhoneOff, Pin, Play, Plus, RefreshCw, RotateCcw, RotateCw, Search, Send, Settings, Settings2, ShieldAlert, ShieldCheck, Shrink, SlidersHorizontal, Sparkles, Square, SquarePen, Star, Sun, Terminal, TerminalSquare, ThumbsDown, ThumbsUp, Trash, Trash2, TriangleAlert, Volume2, Wrench, X, Zap, ZoomIn, ZoomOut
