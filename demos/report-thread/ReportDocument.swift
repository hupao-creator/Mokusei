import SwiftUI
import WebKit

/// One WebKit view survives list/detail changes, retaining the report's scroll position.
struct ReportDocument: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(Self.html, baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static let html = """
    <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
    <style>
    :root { color-scheme: light dark; --bg:#f4f7fb; --ink:#1b2b40; --muted:#536984; --line:#d5e0ee; --paper:#fff; --blue:#2a60b1 }
    @media(prefers-color-scheme:dark) { :root { --bg:#25282e; --ink:#e6eaf1; --muted:#acb9cb; --line:#414a59; --paper:#2d333c; --blue:#91baff } }
    * { box-sizing:border-box } body { margin:0; background:var(--bg); color:var(--ink); font:15px/1.85 -apple-system,BlinkMacSystemFont,sans-serif }
    main { max-width:1000px; margin:auto; padding:72px clamp(30px,6vw,80px) 72px }
    .eyebrow { color:var(--blue); font-size:12px; font-weight:700; letter-spacing:1.8px }
    h1 { font-size:clamp(30px,4.4vw,48px); line-height:1.25; letter-spacing:-1.3px; margin:20px 0 24px; font-weight:750 }
    .intro { color:var(--muted); margin:0 0 40px; line-height:1.95 }
    .columns { display:grid; grid-template-columns:1fr 1fr; gap:16px }
    section { background:var(--paper); border:1px solid var(--line); border-radius:18px; padding:24px }
    h2 { margin:0 0 20px; font-size:24px; letter-spacing:-.7px } .number { font-size:44px; line-height:1.2; color:var(--blue); font-weight:750 }
    .caption { color:var(--muted); font-size:12px; margin:4px 0 20px }
    table { width:100%; border-collapse:collapse; font-size:12px } th { text-align:left; color:var(--muted); font-weight:600 }
    th,td { padding:9px 0; border-bottom:1px solid var(--line) } th:last-child,td:last-child { text-align:right }
    code { font:11px ui-monospace,SFMono-Regular,Menlo,monospace } .note { font-size:12px; color:var(--muted); margin-top:20px }
    .boundary { margin-top:28px; padding-top:22px; border-top:1px solid var(--line); color:var(--muted); font-size:13px }
    .boundary strong { color:var(--ink) } footer { margin-top:36px; color:var(--muted); font-size:11px }
    ::-webkit-scrollbar { width:5px; height:5px } ::-webkit-scrollbar-track { background:transparent }
    ::-webkit-scrollbar-thumb { background:#8e99aa66; border-radius:5px }
    @media(max-width:680px) { .columns { grid-template-columns:1fr } main { padding-top:64px } h1 { font-size:32px } }
    </style></head><body><main>
    <div class="eyebrow">MOKUSEI · 保留记录分析</div>
    <h1>两个后台 Agent 的工具调用样本</h1>
    <p class="intro">只统计绑定到 Mokusei 目录的留存记录。两份样本来源和覆盖范围不同，数字不能用来比较总体使用量。</p>
    <div class="columns"><section><h2>Report Agent</h2><div class="number">104</div>
    <div class="caption">次调用 · 93 成功 · 11 失败 · 0 未决</div>
    <table><tr><th>工具</th><th>调用</th></tr>
    <tr><td><code>read_thread</code></td><td>28</td></tr>
    <tr><td><code>get_thread_status</code></td><td>22</td></tr>
    <tr><td><code>create_report</code></td><td>20</td></tr>
    <tr><td><code>read_lifecycle_events</code></td><td>18</td></tr>
    <tr><td><code>list_reports</code></td><td>8</td></tr>
    <tr><td><code>update_report</code></td><td>6</td></tr>
    <tr><td><code>read_report</code></td><td>2</td></tr>
    <tr><td><code>list_threads</code></td><td>0</td></tr></table>
    <p class="note">调用主要集中在读取上下文和创建报告；失败调用仍计入当前样本。</p></section>
    <section><h2>Tag Agent</h2><div class="number">124</div>
    <div class="caption">次调用 · 72 批 · 记录的工具错误 0</div>
    <table><tr><th>工具</th><th>调用</th></tr>
    <tr><td><code>set_thread_tags</code></td><td>98</td></tr>
    <tr><td><code>read_overview_context</code></td><td>19</td></tr>
    <tr><td><code>create_tags</code></td><td>7</td></tr>
    <tr><td><code>rename_tag</code></td><td>0</td></tr>
    <tr><td><code>merge_tags</code></td><td>0</td></tr>
    <tr><td><code>delete_tag</code></td><td>0</td></tr>
    <tr><td><code>select_tag_filter</code></td><td>0</td></tr></table>
    <p class="note">仅两份可按目录核实的持久化会话；记录时间跨 11 月 2 日与 4 日。另有 4 次失败执行，不能等同于工具错误。</p></section></div>
    <div class="boundary"><strong>如何阅读这份报告</strong><br>结合右侧关联执行查看原始任务和结论。当前报告说明留存样本的调用结构，不代表两个 Agent 的全部历史活动。</div>
    <footer>更新于 11 月 4 日 · Mokusei</footer>
    </main></body></html>
    """
}
