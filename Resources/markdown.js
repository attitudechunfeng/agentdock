// 聊天页的 Markdown 渲染设置。对话内容来自各个 agent 的输出，不可信：
// - 原始 HTML 一律转义后显示，不进页面执行
// - 链接和图片只放行安全的地址：javascript:、data: 文档、file: 链接这些只留文字
(function (root) {
  const esc = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  /// 地址安全就返回能写进 href / src 的写法，否则返回 null
  function safeUrl(href, images) {
    if (!href) return null;
    // 浏览器解析地址时会忽略控制字符和空白，判断协议前先去掉，免得“java\nscript:”混过去
    const probe = String(href).replace(/[\u0000-\u0020\u007f]/g, '').toLowerCase();
    let ok = /^(https?:|mailto:)/.test(probe);
    if (images) {
      // 图片还认本机文件（agent 贴的截图）和内嵌的图片数据
      ok = ok || /^file:/.test(probe) || /^data:image\//.test(probe) || /^\/[^/]/.test(probe);
    }
    if (!ok) return null;
    try { return encodeURI(href).replace(/%25/g, '%'); } catch (e) { return null; }
  }

  function install(marked) {
    marked.use({
      gfm: true, breaks: true,
      renderer: {
        html(t) { return esc(t.raw ?? t.text ?? ''); },
        link(t) {
          const text = this.parser.parseInline(t.tokens);
          const href = safeUrl(t.href, false);
          if (href === null) return text;
          return '<a href="' + href + '"' + (t.title ? ' title="' + esc(t.title) + '"' : '') + '>' + text + '</a>';
        },
        image(t) {
          const href = safeUrl(t.href, true);
          if (href === null) return esc(t.text || '');
          return '<img src="' + href + '" alt="' + esc(t.text || '') + '"' + (t.title ? ' title="' + esc(t.title) + '"' : '') + '>';
        }
      }
    });
  }

  if (typeof module === 'object' && module.exports) module.exports = { install, safeUrl };
  else { root.esc = esc; root.installMarkdown = install; }
})(typeof globalThis !== 'undefined' ? globalThis : this);
