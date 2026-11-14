import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../security/lock_service.dart';
import 'theme.dart';

/// 解锁页：冷启动、以及切后台超过 30 秒回来时显示
class LockPage extends StatefulWidget {
  const LockPage({super.key});

  @override
  State<LockPage> createState() => _LockPageState();
}

class _LockPageState extends State<LockPage> {
  String _pin = '';
  String? _error;
  bool _bioAvailable = true;
  bool _busy = false;
  bool _bioPrompted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepareBiometric());
  }

  Future<void> _prepareBiometric() async {
    final lock = context.read<LockService>();
    final available = await lock.canUseBiometric();
    if (!mounted) return;
    setState(() => _bioAvailable = available);
    // 有指纹就优先弹，日常几乎不用输 PIN
    if (available && !_bioPrompted) {
      _bioPrompted = true;
      _tryBiometric();
    }
  }

  Future<void> _tryBiometric() async {
    final lock = context.read<LockService>();
    final ok = await lock.authenticateBiometric();
    if (!mounted) return;
    if (ok) {
      lock.unlock();
    }
  }

  void _onDigit(String d) {
    if (_pin.length >= 6) return;
    setState(() {
      _pin += d;
      _error = null;
    });
  }

  void _onDelete() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    if (_pin.length < 4 || _busy) return;
    final lock = context.read<LockService>();
    setState(() => _busy = true);
    // 哈希有 12000 轮迭代，放一帧之后执行，避免按钮点击反馈卡顿
    await Future<void>.delayed(const Duration(milliseconds: 16));
    final ok = lock.verifyPin(_pin);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      lock.unlock();
    } else {
      setState(() {
        _error = 'PIN 不对，再试一次';
        _pin = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: kSeed,
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(Icons.lock_outline, color: Colors.white, size: 30),
            ),
            const SizedBox(height: 18),
            const Text('薪迹已锁定', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              _error ?? '输入 PIN 解锁',
              style: TextStyle(
                fontSize: 13,
                color: _error != null ? kUp : const Color(0xFF8A8F8A),
              ),
            ),
            const SizedBox(height: 24),
            _PinDots(length: _pin.length),
            const Spacer(flex: 2),
            _PinPad(
              onDigit: _onDigit,
              onDelete: _onDelete,
              leftAction: _bioAvailable
                  ? IconButton(
                      onPressed: _tryBiometric,
                      icon: const Icon(Icons.fingerprint, size: 30),
                      tooltip: '用指纹/面容解锁',
                    )
                  : const SizedBox(width: 48),
              bottomAction: FilledButton(
                onPressed: _pin.length >= 4 && !_busy ? _submit : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(200, 48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(_busy ? '验证中…' : '解锁'),
              ),
            ),
            TextButton(
              onPressed: () async {
                final ok = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(builder: (_) => const ForgotPinPage()),
                );
                if (ok == true && context.mounted) {
                  context.read<LockService>().unlock();
                }
              },
              child: const Text('忘记 PIN？'),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// 忘记 PIN：答对提示语即可重设
class ForgotPinPage extends StatefulWidget {
  const ForgotPinPage({super.key});

  @override
  State<ForgotPinPage> createState() => _ForgotPinPageState();
}

class _ForgotPinPageState extends State<ForgotPinPage> {
  final _answerCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  final _hintCtrl = TextEditingController();
  String? _error;
  bool _answerOk = false;

  @override
  void dispose() {
    _answerCtrl.dispose();
    _pinCtrl.dispose();
    _hintCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lock = context.read<LockService>();
    return Scaffold(
      appBar: AppBar(title: const Text('找回 PIN')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: kWarnBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0x66E9B949)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, size: 18, color: Color(0xFF9A6B00)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '薪迹不联网、没有服务器，PIN 无法通过账号找回。'
                    '只能靠你设置时填的提示语重设。',
                    style: const TextStyle(fontSize: 12.5, height: 1.5, color: Color(0xFF6B4E00)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (!_answerOk) ...[
            const Text('你的提示语', style: TextStyle(fontSize: 13, color: Color(0xFF8A8F8A))),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: cardDecoration(),
              child: Text(
                (lock.hint ?? '').isEmpty ? '（未设置提示语）' : lock.hint!,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _answerCtrl,
              decoration: InputDecoration(
                labelText: '填入答案',
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                if (lock.checkHint(_answerCtrl.text)) {
                  setState(() {
                    _answerOk = true;
                    _error = null;
                  });
                } else {
                  setState(() => _error = '答案不对');
                }
              },
              child: const Text('验证'),
            ),
          ] else ...[
            const Text('设置新 PIN', style: TextStyle(fontSize: 13, color: Color(0xFF8A8F8A))),
            const SizedBox(height: 6),
            TextField(
              controller: _pinCtrl,
              keyboardType: TextInputType.number,
              maxLength: 6,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '4–6 位数字',
                border: OutlineInputBorder(),
                counterText: '',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _hintCtrl,
              decoration: InputDecoration(
                labelText: '新的提示语',
                helperText: '要填一个只有你自己懂的答案',
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () async {
                final pin = _pinCtrl.text.trim();
                final hint = _hintCtrl.text.trim();
                if (!RegExp(r'^\d{4,6}$').hasMatch(pin)) {
                  setState(() => _error = 'PIN 必须是 4–6 位数字');
                  return;
                }
                if (hint.isEmpty) {
                  setState(() => _error = '提示语不能为空');
                  return;
                }
                await lock.resetPinAfterHint(newPin: pin, newHint: hint);
                if (context.mounted) Navigator.of(context).pop(true);
              },
              child: const Text('保存并解锁'),
            ),
          ],
        ],
      ),
    );
  }
}

/// 设置应用锁（首启引导、设置页都用这个）
class SetupLockPage extends StatefulWidget {
  const SetupLockPage({super.key, this.allowSkip = true});

  final bool allowSkip;

  @override
  State<SetupLockPage> createState() => _SetupLockPageState();
}

class _SetupLockPageState extends State<SetupLockPage> {
  int _step = 0;
  String _pin = '';
  String _confirm = '';
  String? _error;
  final _hintCtrl = TextEditingController();
  bool _useBiometric = true;
  bool _bioSupported = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final supported = await context.read<LockService>().canUseBiometric();
      if (mounted) setState(() => _bioSupported = supported);
    });
  }

  @override
  void dispose() {
    _hintCtrl.dispose();
    super.dispose();
  }

  void _append(String d) {
    setState(() {
      if (_step == 0) {
        if (_pin.length < 6) _pin += d;
      } else if (_step == 1) {
        if (_confirm.length < 6) _confirm += d;
      }
      _error = null;
    });
  }

  void _del() {
    setState(() {
      if (_step == 0 && _pin.isNotEmpty) {
        _pin = _pin.substring(0, _pin.length - 1);
      } else if (_step == 1 && _confirm.isNotEmpty) {
        _confirm = _confirm.substring(0, _confirm.length - 1);
      }
    });
  }

  void _nextFromPin() {
    if (_pin.length < 4) {
      setState(() => _error = '至少 4 位');
      return;
    }
    setState(() => _step = 1);
  }

  void _nextFromConfirm() {
    if (_confirm != _pin) {
      setState(() {
        _error = '两次输入不一致';
        _confirm = '';
      });
      return;
    }
    setState(() => _step = 2);
  }

  Future<void> _finish() async {
    final hint = _hintCtrl.text.trim();
    if (hint.isEmpty) {
      setState(() => _error = '提示语不能为空，这是你唯一能找回 PIN 的办法');
      return;
    }
    if (hint == _pin) {
      setState(() => _error = '提示语不能和 PIN 一样');
      return;
    }
    await context.read<LockService>().setupPin(
          pin: _pin,
          hintText: hint,
          enableBiometric: _bioSupported && _useBiometric,
        );
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('开启应用锁'),
        actions: [
          if (widget.allowSkip && _step < 2)
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('以后再说'),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _step == 0
                    ? '第 1 步 / 3：设置一个 PIN'
                    : _step == 1
                        ? '第 2 步 / 3：再输一次确认'
                        : '第 3 步 / 3：设置找回提示语',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _step == 2
                    ? '薪迹没有服务器，忘记 PIN 时只能靠这句提示找回'
                    : '工资数据比较敏感，解锁后才能查看',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF8A8F8A), height: 1.5),
              ),
            ),
            const SizedBox(height: 20),
            if (_step < 2) ...[
              _PinDots(length: _step == 0 ? _pin.length : _confirm.length),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(fontSize: 13, color: kUp)),
              ],
              const Spacer(),
              _PinPad(
                onDigit: _append,
                onDelete: _del,
                leftAction: const SizedBox(width: 48),
                bottomAction: FilledButton(
                  onPressed: _step == 0 ? _nextFromPin : _nextFromConfirm,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(200, 48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('下一步'),
                ),
              ),
              const SizedBox(height: 16),
            ] else ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    TextField(
                      controller: _hintCtrl,
                      decoration: InputDecoration(
                        labelText: '提示语',
                        hintText: '例如：老家门牌号',
                        helperText: '答案只有你自己知道，别写得太明显',
                        errorText: _error,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    if (_bioSupported) ...[
                      const SizedBox(height: 12),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _useBiometric,
                        onChanged: (v) => setState(() => _useBiometric = v),
                        title: const Text('启用指纹 / 面容解锁', style: TextStyle(fontSize: 14)),
                        subtitle: const Text('日常用指纹，忘记时才输 PIN',
                            style: TextStyle(fontSize: 12)),
                      ),
                    ],
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _finish,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 50),
                          shape:
                              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('完成并开启'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 复用组件

class _PinDots extends StatelessWidget {
  final int length;
  const _PinDots({required this.length});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(6, (i) {
        final filled = i < length;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 7),
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? kSeed : Colors.transparent,
            border: Border.all(color: filled ? kSeed : const Color(0xFFCBD1CB), width: 1.5),
          ),
        );
      }),
    );
  }
}

/// 数字键盘
class _PinPad extends StatelessWidget {
  final void Function(String) onDigit;
  final VoidCallback onDelete;
  final Widget leftAction;
  final Widget bottomAction;

  const _PinPad({
    required this.onDigit,
    required this.onDelete,
    required this.leftAction,
    required this.bottomAction,
  });

  @override
  Widget build(BuildContext context) {
    Widget key(String label) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: InkWell(
            onTap: () => onDigit(label),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              height: 58,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE9EBE9)),
              ),
              child: Text(label, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w500)),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          for (final row in const [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
          ])
            Row(children: row.map(key).toList()),
          Row(
            children: [
              Expanded(child: Center(child: leftAction)),
              key('0'),
              Expanded(
                child: Center(
                  child: IconButton(
                    onPressed: onDelete,
                    icon: const Icon(Icons.backspace_outlined),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          bottomAction,
        ],
      ),
    );
  }
}
