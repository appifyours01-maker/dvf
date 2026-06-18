import 'package:flutter/material.dart';

import 'services/api_service.dart';

class ChatBotPage extends StatefulWidget {
  final String shopName;
  final String appName;

  const ChatBotPage({
    super.key,
    required this.shopName,
    required this.appName,
  });

  @override
  State<ChatBotPage> createState() => _ChatBotPageState();
}

class _ChatBotPageState extends State<ChatBotPage> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _checkingPremium = true;
  bool _isPremium = false;

  final List<_ChatMessage> _messages = <_ChatMessage>[];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    bool premium = false;
    try {
      premium = await ApiService().hasActiveSubscription();
    } catch (_) {
      premium = false;
    }

    if (!mounted) return;

    setState(() {
      _isPremium = premium;
      _checkingPremium = false;
      _messages.add(
        _ChatMessage.bot(
          "Hi! I'm your ${widget.shopName} assistant. How can I help you today?",
        ),
      );
    });

    _scrollToBottom();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  void _send(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    setState(() {
      _messages.add(_ChatMessage.user(trimmed));
    });
    _controller.clear();
    _scrollToBottom();

    Future<void>.delayed(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final reply = _replyFor(trimmed);
      setState(() {
        _messages.add(_ChatMessage.bot(reply));
      });
      _scrollToBottom();
    });
  }

  String _replyFor(String input) {
    final t = input.toLowerCase();

    if (t.contains('order') && (t.contains('track') || t.contains('status'))) {
      return 'To track your order, open Orders in the app and select your latest order.';
    }

    if (t.contains('return') || t.contains('refund')) {
      return 'For returns/refunds, go to Orders > Select item > Return/Refund and follow the steps.';
    }

    if (t.contains('delivery') || t.contains('shipping')) {
      return 'Delivery usually takes 2-5 business days depending on your location.';
    }

    if (t.contains('payment') || t.contains('cod') || t.contains('upi')) {
      return 'We support multiple payment options. Choose your preferred method at checkout.';
    }

    return "Thanks! I can help with order tracking, returns/refunds, delivery and payments. Try a quick option below.";
  }

  List<String> get _quickReplies => const <String>[
        'Track my order',
        'Delivery time',
        'Return / Refund',
        'Payment options',
      ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.shopName} Support'),
      ),
      body: _checkingPremium
          ? const Center(child: CircularProgressIndicator())
          : !_isPremium
              ? _buildPremiumRequired(context)
              : _buildChat(context),
    );
  }

  Widget _buildPremiumRequired(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          const Icon(Icons.lock_outline, size: 56),
          const SizedBox(height: 16),
          const Text(
            'Chatbot is a Premium feature',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Upgrade your plan to enable chatbot for ${widget.shopName}.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildChat(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            itemCount: _messages.length,
            itemBuilder: (context, index) {
              final m = _messages[index];
              return Align(
                alignment: m.isUser ? Alignment.centerRight : Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.78,
                  ),
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: m.isUser
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      m.text,
                      style: TextStyle(
                        color: m.isUser
                            ? Theme.of(context).colorScheme.onPrimary
                            : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _quickReplies
                  .map(
                    (q) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        label: Text(q),
                        onPressed: () => _send(q),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.send,
                    onSubmitted: _send,
                    decoration: const InputDecoration(
                      hintText: 'Type a message…',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: () => _send(_controller.text),
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ChatMessage {
  final bool isUser;
  final String text;

  const _ChatMessage._(this.isUser, this.text);

  factory _ChatMessage.user(String text) => _ChatMessage._(true, text);
  factory _ChatMessage.bot(String text) => _ChatMessage._(false, text);
}
