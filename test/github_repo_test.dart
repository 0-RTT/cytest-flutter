import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/github.dart';

void main() {
  group('parseRepoSlug 把仓库地址规范化成 owner/repo', () {
    test('完整 https 地址', () {
      expect(parseRepoSlug('https://github.com/0-RTT/sub'), '0-RTT/sub');
    });

    test('带 .git 后缀', () {
      expect(parseRepoSlug('https://github.com/0-RTT/sub.git'), '0-RTT/sub');
    });

    test('http + 尾部斜杠', () {
      expect(parseRepoSlug('http://github.com/0-RTT/sub/'), '0-RTT/sub');
    });

    test('省略协议头的主机名形式', () {
      expect(parseRepoSlug('github.com/0-RTT/sub'), '0-RTT/sub');
    });

    test('已规范化的 owner/repo 原样返回', () {
      expect(parseRepoSlug('0-RTT/sub'), '0-RTT/sub');
    });

    test('首尾空白被 trim', () {
      expect(parseRepoSlug('  https://github.com/0-RTT/sub \n'), '0-RTT/sub');
    });

    test('query 与 fragment 被丢弃', () {
      expect(
        parseRepoSlug('https://github.com/0-RTT/sub?tab=readme#install'),
        '0-RTT/sub',
      );
    });

    test('.git + 尾部斜杠 + query 组合', () {
      expect(
        parseRepoSlug('https://github.com/0-RTT/sub.git/?ref=main'),
        '0-RTT/sub',
      );
    });

    test('www / api.github.com/repos 主机名同样支持', () {
      expect(parseRepoSlug('https://www.github.com/0-RTT/sub'), '0-RTT/sub');
      expect(
        parseRepoSlug('https://api.github.com/repos/0-RTT/sub'),
        '0-RTT/sub',
      );
    });

    test('scp 写法 git@github.com:owner/repo.git', () {
      expect(parseRepoSlug('git@github.com:0-RTT/sub.git'), '0-RTT/sub');
    });

    test('多余子路径（/tree/main）只取前两段', () {
      expect(
        parseRepoSlug('https://github.com/0-RTT/sub/tree/main/docs'),
        '0-RTT/sub',
      );
    });

    group('无法解析时返回空串', () {
      test('空串', () {
        expect(parseRepoSlug(''), '');
      });

      test('只有空白', () {
        expect(parseRepoSlug('   '), '');
      });

      test('缺 repo（只给了 owner）', () {
        expect(parseRepoSlug('https://github.com/0-RTT'), '');
        expect(parseRepoSlug('0-RTT'), '');
      });

      test('缺 owner（以斜杠开头）', () {
        expect(parseRepoSlug('/sub'), '');
        expect(parseRepoSlug('https://github.com//sub'), '');
      });

      test('只有主机名', () {
        expect(parseRepoSlug('https://github.com'), '');
        expect(parseRepoSlug('github.com/'), '');
      });

      test('repo 只剩 .git 后缀', () {
        expect(parseRepoSlug('0-RTT/.git'), '');
      });
    });
  });
}
