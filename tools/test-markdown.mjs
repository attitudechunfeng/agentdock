// 聊天页 Markdown 渲染的单元测试：node tools/test-markdown.mjs
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const marked = require('../Resources/marked.umd.js');
const { install, safeUrl } = require('../Resources/markdown.js');
install(marked);

let failed = 0;
function check(name, got, want) {
  if (got === want) return;
  failed++;
  console.log('FAIL ' + name + '\n  得到 ' + got + '\n  应为 ' + want);
}
// 只看段落里的内容
const render = s => marked.parse(s).trim().replace(/^<p>|<\/p>$/g, '');

// 不安全的地址只留文字
check('javascript 链接', render('[x](javascript:alert(1))'), 'x');
check('协议名大小写', render('[x](JavaScript:alert(1))'), 'x');
check('协议名里夹制表符', render('[x](<java\tscript:alert(1)>)'), 'x');
check('vbscript', render('[x](vbscript:msgbox)'), 'x');
check('data 文档', render('[x](data:text/html,<b>hi</b>)'), 'x');
check('file 链接', render('[x](file:///etc/passwd)'), 'x');
check('没有协议名', render('[x](//evil.com/a)'), 'x');
check('javascript 图片', render('![alt](javascript:alert(1))'), 'alt');
check('data 文档当图片', render('![alt](data:text/html;base64,AA)'), 'alt');
check('没有协议名的图片', render('![x](//evil.com/a.gif)'), 'x');

// 安全的地址照常渲染，写法和 marked 默认的一样
check('https 链接', render('[ok](https://example.com/a?b=1&c=2 "ti\\"tle")'),
  '<a href="https://example.com/a?b=1&c=2" title="ti&quot;tle">ok</a>');
check('mailto', render('[m](mailto:a@b.com)'), '<a href="mailto:a@b.com">m</a>');
check('邮箱自动成链', render('<a@b.com>'), '<a href="mailto:a@b.com">a@b.com</a>');
check('网址自动成链', render('www.example.com'), '<a href="http://www.example.com">www.example.com</a>');
check('链接文字里的格式', render('[**b** and <i>x</i>](https://e.com)'), '<a href="https://e.com"><strong>b</strong> and &lt;i&gt;x&lt;/i&gt;</a>');
check('内嵌图片', render('![alt](data:image/png;base64,AA)'), '<img src="data:image/png;base64,AA" alt="alt">');
check('本机图片', render('![alt](/tmp/shot.png)'), '<img src="/tmp/shot.png" alt="alt">');
check('file 图片', render('![alt](file:///tmp/shot.png "the title")'), '<img src="file:///tmp/shot.png" alt="alt" title="the title">');
check('图片说明里的引号', render('![x" onerror="alert(1)](https://example.com/a.png)'),
  '<img src="https://example.com/a.png" alt="x&quot; onerror=&quot;alert(1)">');
check('原始 HTML 转义', render('<script>alert(1)</script>'), '&lt;script&gt;alert(1)&lt;/script&gt;');

check('safeUrl 去掉空白再判断', safeUrl(' javascript:alert(1)', false), null);
check('safeUrl 换行', safeUrl('java\nscript:alert(1)', false), null);
check('safeUrl https', safeUrl('https://e.com/a b', false), 'https://e.com/a%20b');
check('safeUrl 空', safeUrl('', false), null);
check('safeUrl 图片不认 ~', safeUrl('~/a.png', true), null);
check('safeUrl 链接不认本机文件', safeUrl('file:///tmp/a.png', false), null);

console.log(failed ? failed + ' failed' : 'markdown tests passed');
process.exit(failed ? 1 : 0);
