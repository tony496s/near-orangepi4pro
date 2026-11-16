import 'package:flutter/widgets.dart';

import '../ui/theme.dart';
import 'console_app.dart';

/// One device in the comparison.
typedef WhyRow = ({String device, String runsOn, String lidClosed, String isolated, String controls, String price});

/// The closing screen of the demo: every other agent gadget is a remote for a laptop that must stay open.
const whyRows = <WhyRow>[
  (device: 'Near', runsOn: 'Trong hộp', lidClosed: 'Vẫn chạy', isolated: 'Có', controls: 'Màn chạm + giọng local', price: '~\$299'),
  (device: 'Núm / Pro Harness', runsOn: 'Trên laptop', lidClosed: 'Dừng', isolated: 'Không', controls: 'Núm, màn nhỏ', price: '\$129–299'),
  (device: 'SlashVibe, MX Keypad', runsOn: 'Trên laptop', lidClosed: 'Dừng', isolated: 'Không', controls: 'Phím tắt', price: '\$99–169'),
  (device: 'Remote trên điện thoại', runsOn: 'Trên laptop', lidClosed: 'Dừng', isolated: 'Không', controls: 'App, chạm từng lệnh', price: 'Miễn phí'),
  (device: 'Mac mini', runsOn: 'Trong máy', lidClosed: 'Vẫn chạy', isolated: 'Có', controls: 'Không có', price: '\$599'),
];

const _cols = [250.0, 150.0, 150.0, 110.0, 250.0, 110.0];

class WhyScreen extends StatelessWidget {
  const WhyScreen({super.key, required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => GestureDetector(
        key: const Key('why'),
        behavior: HitTestBehavior.opaque,
        onTap: onClose,
        child: Container(
          color: const Color(0xFF071216),
          padding: const EdgeInsets.fromLTRB(36, 22, 36, 18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 300,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    eyebrowText('VÌ SAO LÀ NEAR', Ink.hot),
                    const SizedBox(height: 12),
                    Text('Gập laptop,\nđội agent vẫn chạy.', style: cs(29, weight: FontWeight.w500, height: 1.2)),
                    const SizedBox(height: 12),
                    Text('Mọi thiết bị khác chỉ là cái remote cho laptop đang mở.',
                        style: cs(16, color: Ink.dim, height: 1.35)),
                    const Spacer(),
                    Text('Chạm để quay lại', style: cs(13, color: Ink.faint)),
                  ],
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  children: [
                    _row(const ['', 'Agent chạy ở', 'Gập laptop', 'Cách ly', 'Điều khiển', 'Giá'], header: true),
                    for (final r in whyRows)
                      Expanded(
                        child: _row([r.device, r.runsOn, r.lidClosed, r.isolated, r.controls, r.price],
                            near: r.device == 'Near'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _row(List<String> cells, {bool header = false, bool near = false}) {
    Color colorOf(int i) {
      if (header) return Ink.dim;
      if (i == 0) return near ? Ink.hot : Ink.ink;
      final good = {'Trong hộp', 'Trong máy', 'Vẫn chạy', 'Có'}.contains(cells[i]);
      final bad = {'Trên laptop', 'Dừng', 'Không', 'Không có'}.contains(cells[i]);
      return good ? Ink.cool : (bad ? Ink.faint : Ink.ink);
    }

    return Container(
      height: header ? 30 : null,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: near ? const Color(0x1F86D8CC) : null,
        borderRadius: near ? BorderRadius.circular(12) : null,
        border: near || header ? null : const Border(top: BorderSide(color: Ink.hair)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < cells.length; i++)
            SizedBox(
              width: _cols[i],
              child: Text(
                cells[i],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: header
                    ? cs(13, weight: FontWeight.w600, color: colorOf(i), spacing: 1)
                    : cs(i == 0 ? 18 : 17, weight: i == 0 || near ? FontWeight.w600 : FontWeight.w400, color: colorOf(i)),
              ),
            ),
        ],
      ),
    );
  }
}
