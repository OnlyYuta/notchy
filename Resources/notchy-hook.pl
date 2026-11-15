#!/usr/bin/perl
# Lumio: передаёт событие Claude Code, Gemini CLI, Copilot, Cursor или Antigravity в островок. Оставляет только короткие поля
# и всегда завершается успешно — на работу агента не влияет.
# rev hw3zkqv
use strict;
use warnings;
use JSON::PP;
use Time::HiRes ();

my $mode = $ARGV[0] // '';
my $raw = do { local $/; <STDIN> } // '';
my $event = eval { JSON::PP->new->utf8->decode($raw) };
my $support = "$ENV{HOME}/Library/Application Support/Notchy";

# Gemini CLI: проверка перед действием. Ответ — решение для Gemini (JSON в stdout).
if ($mode eq 'gemini-ask') { print gemini_ask($event); exit 0; }
# Gemini CLI: обычное событие. Gemini ждёт JSON в ответ — пустой объект ничего не меняет.
if ($mode eq 'gemini') {
    print '{}';
    exit 0 unless ref $event eq 'HASH';
    my $t = gemini_event($event) or exit 0;
    write_event($t);
    # Карточку покажет режим gemini-ask — статус «ждёт» пишем сразу после шага, по порядку.
    if ($t->{hook_event_name} eq 'PreToolUse' && gemini_gated($event) && alive()) {
        write_event({ %$t, hook_event_name => 'PermissionRequest' });
    }
    exit 0;
}
# GitHub Copilot в VS Code: проверка команды перед запуском. Ответ — решение для VS Code.
if ($mode eq 'copilot-ask') { print copilot_ask($event); exit 0; }
# GitHub Copilot: обычное событие (формат почти как у Claude Code).
if ($mode eq 'copilot') {
    print '{}';
    exit 0 unless ref $event eq 'HASH';
    my $t = copilot_event($event) or exit 0;
    write_event($t);
    if ($t->{hook_event_name} eq 'PreToolUse' && alive()
        && (copilot_gated($event) || ($event->{tool_name} // '') eq 'AskUserQuestion')) {
        write_event({ %$t, hook_event_name => 'PermissionRequest' });
    }
    exit 0;
}
# Cursor: событие (формат свой). Cursor ждёт JSON в ответ — пустой объект ничего не меняет.
# Разрешать команды за человека Cursor хукам не даёт (свою кнопку Run показывает всё равно),
# поэтому ничего не ждём: если Cursor спросит про команду, сразу пишем «ждёт разрешения».
if ($mode eq 'cursor') {
    print '{}';
    exit 0 unless ref $event eq 'HASH';
    my $t = cursor_event($event) or exit 0;
    write_event($t);
    if ($t->{hook_event_name} eq 'PreToolUse' && cursor_gated($event)) {
        write_event({ %$t, hook_event_name => 'PermissionRequest' });
        cursor_request($t);
    } elsif ($t->{hook_event_name} ne 'PreToolUse') {
        cursor_clear($t->{session_id});
    }
    exit 0;
}
# Google Antigravity: событие приходит аргументом (в JSON его нет). Ответ — решение для Antigravity.
if ($mode eq 'antigravity') { print agy($ARGV[1] // '', $event); exit 0; }
exit 0 unless ref $event eq 'HASH';
# Cursor запускает и хуки Claude Code — его события приходят через режим cursor, здесь пропускаем.
exit 0 if defined $event->{cursor_version};
if ($mode eq 'ask') { ask($event); exit 0; }
# Claude Code (аргумент claude или без аргумента) и Codex присылают события в одном формате.
if ($mode eq 'codex') {
    $event->{lumio_agent} = 'codex';
    $event->{session_id} = 'codex-' . ($event->{session_id} // '');
} else {
    $event->{lumio_agent} = 'claude';
}
write_event($event);
exit 0;

sub write_event {
    my ($event) = @_;
    my %out;
    for my $key (qw(session_id cwd hook_event_name tool_name notification_type message source
                    reason agent_id agent_type prompt last_assistant_message tool_error
                    task_id task_subject task_description subject lumio_agent lumio_question transcript_path)) {
        next unless defined $event->{$key} && !ref $event->{$key};
        my $limit = $key eq 'last_assistant_message' ? 8000 : 600;
        $out{$key} = substr($event->{$key}, 0, $limit);
    }
    if (ref $event->{tool_input} eq 'HASH') {
        my %input;
        for my $key (qw(file_path notebook_path command description pattern path url query subagent_type)) {
            my $value = $event->{tool_input}{$key};
            $input{$key} = substr($value, 0, 300) if defined $value && !ref $value;
        }
        # План агента (TodoWrite): только названия и статусы пунктов.
        if (ref $event->{tool_input}{todos} eq 'ARRAY') {
            my @todos;
            for my $todo (@{ $event->{tool_input}{todos} }) {
                next unless ref $todo eq 'HASH';
                push @todos, {
                    content    => substr($todo->{content} // '', 0, 120),
                    activeForm => substr($todo->{activeForm} // '', 0, 120),
                    status     => ($todo->{status} // ''),
                };
                last if @todos >= 20;
            }
            $input{todos} = \@todos;
        }
        $out{tool_input} = \%input;
    }
    $out{ts} = time;
    my $log = "$support/agent-events.jsonl";
    # Журнал не растёт бесконечно, даже если приложение не запущено.
    my $size = -s $log;
    my $open = (defined $size && $size > 2_000_000) ? '>' : '>>';
    open(my $fh, $open, $log) or return;
    print $fh JSON::PP->new->utf8->canonical->encode(\%out), "\n";
    close $fh;
}

# Lumio запущен и отвечает из чёлки (файл обновляется каждые 4 с).
sub alive { my @st = stat "$support/ask/alive"; return @st && time - $st[9] < 15; }

# Пишет запрос для чёлки и ждёт ответа до 2 минут. Без ответа или без Lumio — undef.
sub wait_answer {
    my ($body) = @_;
    my $dir = "$support/ask";
    my $json = JSON::PP->new->utf8->canonical;
    my $id = sprintf('%d-%d', time, $$);
    my $request = "$dir/$id.request.json";
    my $reply = "$dir/$id.answer.json";
    open(my $fh, '>', "$request.tmp") or return;
    print $fh $json->encode({ %$body, pid => $$, ts => time });
    close $fh;
    rename("$request.tmp", $request) or return;
    local $SIG{TERM} = sub { unlink $request; exit 0 };
    local $SIG{INT}  = sub { unlink $request; exit 0 };
    local $SIG{HUP}  = sub { unlink $request; exit 0 };
    my $answer;
    my $deadline = time + 120;
    while (time < $deadline) {
        if (-e $reply) {
            if (open(my $rh, '<', $reply)) { local $/; my $text = <$rh>; $answer = eval { $json->decode($text) }; }
            last;
        }
        last unless -e $request && alive();
        Time::HiRes::sleep(0.2);
    }
    unlink $request, $reply;
    return ref $answer eq 'HASH' ? $answer : undef;
}

# Ответ из чёлки Lumio. Без ответа — ничего не печатаем, и Claude Code спрашивает сам.
sub ask {
    my ($event) = @_;
    return unless alive();
    my $tool = $event->{tool_name} // '';
    return if $tool eq '';
    my $in = ref $event->{tool_input} eq 'HASH' ? $event->{tool_input} : {};
    my %input;
    if ($tool eq 'AskUserQuestion') {
        %input = (questions => $in->{questions});
    } else {
        for my $key (qw(command description file_path notebook_path url pattern path query)) {
            my $value = $in->{$key};
            $input{$key} = substr($value, 0, 600) if defined $value && !ref $value;
        }
    }
    my $answer = wait_answer({ session_id => ($event->{session_id} // ''), cwd => ($event->{cwd} // ''),
                               tool_name => $tool, tool_input => \%input }) or return;
    my $behavior = $answer->{behavior} // '';
    my %decision;
    if ($behavior eq 'allow') {
        %decision = (behavior => 'allow');
        if (ref $answer->{answers} eq 'HASH') {
            $decision{updatedInput} = { %$in, answers => $answer->{answers} };
        }
    } elsif ($behavior eq 'deny') {
        %decision = (behavior => 'deny', message => ($answer->{message} // 'Declined in Lumio.'));
    } else {
        return;
    }
    print JSON::PP->new->utf8->canonical->encode({ hookSpecificOutput => { hookEventName => 'PermissionRequest', decision => \%decision } });
}

# --- Gemini CLI ---
# Его события и инструменты — на языке Claude Code, чтобы островок понимал их одинаково.

my %GEMINI_EVENTS; my %GEMINI_TOOLS; my %GEMINI_GATED;
BEGIN {
    %GEMINI_EVENTS = (SessionStart => 'SessionStart', SessionEnd => 'SessionEnd', BeforeAgent => 'UserPromptSubmit',
                      BeforeTool => 'PreToolUse', AfterTool => 'PostToolUse', AfterAgent => 'Stop',
                      Notification => 'Notification');
    %GEMINI_TOOLS = (run_shell_command => 'Bash', write_file => 'Write', replace => 'Edit', read_file => 'Read',
                     read_many_files => 'Read', list_directory => 'LS', glob => 'Glob', search_file_content => 'Grep',
                     grep_search => 'Grep', web_fetch => 'WebFetch', google_web_search => 'WebSearch',
                     write_todos => 'TodoWrite', ask_user => 'AskUserQuestion');
    # То, что Gemini обычно спрашивает в терминале; с Lumio их спрашивает чёлка (правило lumio.toml).
    %GEMINI_GATED = map { $_ => 1 } qw(run_shell_command write_file replace web_fetch);
}

sub gemini_event {
    my ($e) = @_;
    my $name = $GEMINI_EVENTS{ $e->{hook_event_name} // '' } or return;
    my %t = (session_id => 'gemini-' . ($e->{session_id} // ''), cwd => $e->{cwd}, hook_event_name => $name,
             lumio_agent => 'gemini');
    for my $key (qw(prompt source reason message)) { $t{$key} = $e->{$key} if defined $e->{$key} && !ref $e->{$key}; }
    if (defined $e->{tool_name} && !ref $e->{tool_name}) { $t{tool_name} = $GEMINI_TOOLS{ $e->{tool_name} } // $e->{tool_name}; }
    if (ref $e->{tool_input} eq 'HASH') {
        my %in = %{ $e->{tool_input} };
        $in{file_path} //= $in{absolute_path} if defined $in{absolute_path};
        $in{path} //= $in{dir_path} if defined $in{dir_path} && ($t{tool_name} // '') ne 'Bash';
        if (ref $in{todos} eq 'ARRAY') {
            $in{todos} = [ map { ref $_ eq 'HASH' ? { content => ($_->{description} // ''),
                                 status => (($_->{status} // '') eq 'cancelled' ? 'completed' : ($_->{status} // '')) } : () } @{ $in{todos} } ];
        }
        if (($t{tool_name} // '') eq 'WebFetch' && !defined $in{url} && ($in{prompt} // '') =~ m{(https?://\S+)}) { $in{url} = $1; }
        $t{tool_input} = \%in;
    }
    if ($name eq 'PostToolUse' && ref $e->{tool_response} eq 'HASH') {
        my $error = $e->{tool_response}{error};
        if (defined $error && !ref $error && length $error) { $t{hook_event_name} = 'PostToolUseFailure'; $t{tool_error} = $error; }
    }
    if ($name eq 'Stop') { $t{last_assistant_message} = $e->{prompt_response}; delete $t{prompt}; }
    if ($name eq 'Notification') {
        return unless ($e->{notification_type} // '') eq 'ToolPermission';
        $t{notification_type} = 'permission_prompt';
    }
    return \%t;
}

# Этот шаг Lumio спрашивает в чёлке: команда, запись, правка, загрузка — или вопрос агента.
sub gemini_gated {
    my ($e) = @_;
    my $tool = $e->{tool_name} // '';
    return 0 unless $GEMINI_GATED{$tool} || $tool eq 'ask_user';
    return !gemini_auto($tool);
}

# Gemini сам разрешает это без вопроса: --yolo, план или автоправки.
sub gemini_auto {
    my ($tool) = @_;
    my $mode = '';
    my $pid = getppid();
    for (1 .. 5) {
        last if $pid <= 1;
        my $args = `/bin/ps -o args= -p $pid 2>/dev/null` // '';
        my ($program, $script) = split ' ', $args;
        # Сам процесс Gemini: «gemini …» или «node …/gemini …». Его флаги и решают.
        if (($program // '') =~ m{(?:^|/)gemini$} || (($program // '') =~ m{(?:^|/)node$} && ($script // '') =~ m{(?:^|/)gemini(?:\.js)?$|gemini-cli})) {
            if ($args =~ /(?:\s--yolo\b|\s-y(?:\s|$)|\s--approval-mode[= ]yolo)/) { $mode = 'yolo'; }
            elsif ($args =~ /\s--approval-mode[= ](auto_edit|plan)/) { $mode = $1; }
            last;
        }
        my $parent = `/bin/ps -o ppid= -p $pid 2>/dev/null` // '';
        $parent =~ s/\D//g;
        $pid = $parent || 0;
    }
    if (!$mode && open(my $fh, '<', "$ENV{HOME}/.gemini/settings.json")) {
        local $/; my $settings = eval { JSON::PP->new->relaxed->decode(<$fh>) };
        $mode = $settings->{general}{defaultApprovalMode} // '' if ref $settings eq 'HASH' && ref $settings->{general} eq 'HASH';
    }
    return 1 if $mode eq 'yolo' || $mode eq 'plan';
    return 1 if $mode eq 'auto_edit' && $tool =~ /^(?:write_file|replace|web_fetch)$/;
    return 0;
}

# Ответ для Gemini. «ask» — спросить в терминале как обычно; «{}» — Gemini решает сам по своим правилам.
sub gemini_ask {
    my ($e) = @_;
    my $ask = '{"decision":"ask"}';
    return $ask unless ref $e eq 'HASH';
    my $tool = $e->{tool_name} // '';
    my $question = $tool eq 'ask_user';
    return '{}' unless gemini_gated($e);
    return $question ? '{}' : $ask unless alive();
    my $t = gemini_event($e) or return $question ? '{}' : $ask;
    my $in = ref $e->{tool_input} eq 'HASH' ? $e->{tool_input} : {};
    my %input;
    if ($question) {
        my @questions;
        for my $q (ref $in->{questions} eq 'ARRAY' ? @{ $in->{questions} } : ()) {
            next unless ref $q eq 'HASH' && defined $q->{question};
            my @options = ref $q->{options} eq 'ARRAY' ? @{ $q->{options} } : ();
            @options = ({ label => 'Yes', description => '' }, { label => 'No', description => '' }) if ($q->{type} // '') eq 'yesno';
            push @questions, { question => $q->{question}, header => ($q->{header} // ''),
                               multiSelect => ($q->{multiSelect} ? JSON::PP::true : JSON::PP::false), options => \@options };
        }
        return '{}' unless @questions;
        %input = (questions => \@questions);
    } else {
        for my $key (qw(command description file_path url path)) {
            my $value = $t->{tool_input}{$key};
            $input{$key} = substr($value, 0, 600) if defined $value && !ref $value;
        }
    }
    my $answer = wait_answer({ session_id => $t->{session_id}, cwd => ($e->{cwd} // ''),
                               tool_name => $t->{tool_name}, tool_input => \%input });
    my $behavior = $answer ? ($answer->{behavior} // '') : '';
    my $json = JSON::PP->new->utf8->canonical;
    if ($behavior eq 'allow' && $question) {
        # Ответ из чёлки отдаём агенту вместо окна вопроса: Gemini не даёт заполнить его снаружи.
        my $answers = ref $answer->{answers} eq 'HASH' ? $answer->{answers} : {};
        my $text = join('; ', map { "$_: " . ($answers->{$_} // '') } sort keys %$answers);
        return $json->encode({ decision => 'deny',
            reason => "The user already answered in Lumio (the notch app), so this dialog was skipped. Answers: $text. Continue with these answers and don't ask again." });
    }
    return '{}' if $behavior eq 'allow';
    return $json->encode({ decision => 'deny', reason => ($answer->{message} // 'The user declined this in Lumio.') }) if $behavior eq 'deny';
    return $question ? '{}' : $ask;
}

# --- Google Antigravity ---
# Формат — antigravity.google/docs/hooks: conversationId, workspacePaths, toolCall {name, args}.
# Спрашиваем в чёлке только команды терминала; остальное Antigravity решает сам.

my %AGY_TOOLS;
BEGIN {
    %AGY_TOOLS = (run_command => 'Bash', view_file => 'Read', view_file_outline => 'Read', view_code_item => 'Read',
                  write_to_file => 'Write', create_file => 'Write', replace_file_content => 'Edit',
                  multi_replace_file_content => 'Edit', list_dir => 'LS', find_by_name => 'Glob', grep_search => 'Grep',
                  codebase_search => 'Grep', read_url_content => 'WebFetch', search_web => 'WebSearch',
                  browser_subagent => 'Agent');
}

sub agy_event {
    my ($name, $e) = @_;
    my $paths = ref $e->{workspacePaths} eq 'ARRAY' ? $e->{workspacePaths} : [];
    my %t = (session_id => 'agy-' . ($e->{conversationId} // ''), cwd => ($paths->[0] // ''), hook_event_name => $name,
             lumio_agent => 'antigravity');
    my $call = ref $e->{toolCall} eq 'HASH' ? $e->{toolCall} : undef;
    return \%t unless $call;
    my $tool = $call->{name} // '';
    $t{tool_name} = $AGY_TOOLS{$tool} // $tool;
    my $a = ref $call->{args} eq 'HASH' ? $call->{args} : {};
    my $pick = sub { for (@_) { return $a->{$_} if defined $a->{$_} && !ref $a->{$_}; } return; };
    my %in;
    my $v;
    # Только короткие поля: ни содержимого файлов, ни текста правок.
    $in{command} = $v if defined($v = $pick->(qw(CommandLine Command)));
    $in{file_path} = $v if defined($v = $pick->(qw(TargetFile AbsolutePath FilePath File)));
    $in{path} = $v if defined($v = $pick->(qw(DirectoryPath SearchPath SearchDirectory)));
    $in{pattern} = $v if defined($v = $pick->(qw(Query Pattern query)));
    $in{url} = $v if defined($v = $pick->(qw(Url URL url)));
    $in{query} = delete $in{pattern} if $t{tool_name} eq 'WebSearch' && defined $in{pattern};
    $t{tool_input} = \%in;
    return \%t;
}

sub agy {
    my ($name, $e) = @_;
    my $allow = '{"decision":"allow"}';  # «как обычно»: решают правила самого Antigravity
    return $name eq 'PreToolUse' ? $allow : '{}' unless ref $e eq 'HASH';
    # Внутри Antigravity аргументы хука — «common» + аргументы события; документация показывает их одним
    # плоским объектом. Принимаем оба вида.
    if (ref $e->{common} eq 'HASH') {
        my %flat = %{ $e->{common} };
        for my $key (grep { /HookArgs$/ } keys %$e) { %flat = (%flat, %{ $e->{$key} }) if ref $e->{$key} eq 'HASH'; }
        $e = \%flat;
    }
    if ($name eq 'SessionStart') { write_event(agy_event('SessionStart', $e)); return '{}'; }
    if ($name eq 'PreInvocation') {
        # Первый вызов модели — новая задача; следующие — та же работа.
        write_event(agy_event('UserPromptSubmit', $e)) if ($e->{invocationNum} // -1) == 0;
        return '{}';
    }
    if ($name eq 'PostToolUse') {
        my $t = agy_event('PostToolUse', $e);
        my $error = $e->{error};
        if (defined $error && !ref $error && length $error) { $t->{hook_event_name} = 'PostToolUseFailure'; $t->{tool_error} = $error; }
        write_event($t);
        return '{}';
    }
    if ($name eq 'Stop') {
        # Antigravity останавливается и между шагами; закончил — только когда совсем свободен.
        return '{"decision":""}' unless $e->{fullyIdle};
        my $t = agy_event('Stop', $e);
        my $error = $e->{error};
        if (($e->{terminationReason} // '') eq 'error' || (defined $error && !ref $error && length $error)) {
            $t->{hook_event_name} = 'StopFailure';
            $t->{tool_error} = $error if defined $error && !ref $error;
        }
        write_event($t);
        return '{"decision":""}';
    }
    return '{}' unless $name eq 'PreToolUse';
    my $t = agy_event('PreToolUse', $e);
    if (($t->{tool_name} // '') eq 'ask_question') {
        # Ответить можно только в самом Antigravity (хуки не умеют), но чёлка покажет вопрос и что он ждёт.
        my $call = ref $e->{toolCall} eq 'HASH' ? $e->{toolCall} : {};
        my $qs = ref $call->{args} eq 'HASH' && ref $call->{args}{questions} eq 'ARRAY' ? $call->{args}{questions} : [];
        my $first = ref $qs->[0] eq 'HASH' ? $qs->[0]{question} : undef;
        my %n = (%$t, hook_event_name => 'Notification', notification_type => 'agent_needs_input');
        delete @n{qw(tool_name tool_input)};
        $n{lumio_question} = substr($first, 0, 300) if defined $first && !ref $first && length $first;
        write_event(\%n);
        return $allow;
    }
    # Команды решает сам Antigravity, как без Lumio (21.10): чёлка спрашивала и в его режиме «без подтверждения»,
    # и команда ждала. Этот режим Antigravity хранит у себя, прочитать его пока нельзя. Lumio только показывает команду.
    write_event($t);
    return $allow;
}

# --- GitHub Copilot (VS Code) ---
# События уже в формате Claude Code; переводим названия инструментов и поля.

my %COPILOT_TOOLS;
BEGIN {
    %COPILOT_TOOLS = (run_in_terminal => 'Bash', create_file => 'Write', replace_string_in_file => 'Edit',
                      multi_replace_string_in_file => 'Edit', insert_edit_into_file => 'Edit', apply_patch => 'Edit',
                      edit_notebook_file => 'NotebookEdit', read_file => 'Read', list_dir => 'LS', file_search => 'Glob',
                      grep_search => 'Grep', semantic_search => 'Grep', fetch_webpage => 'WebFetch',
                      manage_todo_list => 'TodoWrite', runSubagent => 'Agent');
}

sub copilot_tool {
    my ($name) = @_;
    return $COPILOT_TOOLS{$name} if $COPILOT_TOOLS{$name};
    # Новые или переименованные инструменты — по смыслу названия.
    return 'Bash' if $name =~ /terminal/i;
    return 'Write' if $name =~ /create.?file/i;
    return 'Edit' if $name =~ /replace|edit|patch|insert/i;
    return 'Read' if $name =~ /read/i;
    return 'Grep' if $name =~ /search|find/i;
    return 'WebFetch' if $name =~ /fetch/i;
    return 'TodoWrite' if $name =~ /todo/i;
    return $name;
}

sub copilot_event {
    my ($e) = @_;
    my $name = $e->{hook_event_name} // '';
    return unless $name =~ /^(?:SessionStart|UserPromptSubmit|PreToolUse|PostToolUse|Stop|SubagentStart|SubagentStop)$/;
    my %t = (session_id => 'copilot-' . ($e->{session_id} // ''), cwd => $e->{cwd}, hook_event_name => $name,
             lumio_agent => 'copilot');
    for my $key (qw(prompt source agent_id agent_type)) { $t{$key} = $e->{$key} if defined $e->{$key} && !ref $e->{$key}; }
    if (defined $e->{tool_name} && !ref $e->{tool_name}) { $t{tool_name} = copilot_tool($e->{tool_name}); }
    if (ref $e->{tool_input} eq 'HASH') {
        my $in = $e->{tool_input};
        my %out;
        $out{command} = $in->{command} if defined $in->{command} && !ref $in->{command};
        $out{description} = $in->{explanation} if defined $in->{explanation} && !ref $in->{explanation};
        my $file = $in->{filePath} // $in->{file_path};
        $file = $in->{replacements}[0]{filePath} if !defined $file && ref $in->{replacements} eq 'ARRAY' && ref $in->{replacements}[0] eq 'HASH';
        $out{file_path} = $file if defined $file && !ref $file;
        $out{path} = $in->{path} if defined $in->{path} && !ref $in->{path};
        $out{pattern} = $in->{query} if defined $in->{query} && !ref $in->{query} && ($t{tool_name} // '') =~ /^(?:Grep|Glob)$/;
        $out{url} = $in->{urls}[0] if ref $in->{urls} eq 'ARRAY' && defined $in->{urls}[0] && !ref $in->{urls}[0];
        if (ref $in->{todoList} eq 'ARRAY') {
            my %status = ('not-started' => 'pending', 'in-progress' => 'in_progress', completed => 'completed');
            $out{todos} = [ map { ref $_ eq 'HASH' ? { content => ($_->{title} // ''), status => ($status{ $_->{status} // '' } // 'pending') } : () }
                            @{ $in->{todoList} } ];
        }
        $t{tool_input} = \%out;
    }
    return \%t;
}

# Команды, о которых VS Code и сам не спрашивает (его встроенный список и ваши настройки).
my @COPILOT_SAFE;
BEGIN {
    @COPILOT_SAFE = qw(cd echo ls dir pwd cat head tail findstr wc tr cut cmp which basename dirname realpath
                       readlink stat file od du df sleep nl grep);
}

# Режим чата VS Code (1.142): «Bypass Approvals» (autoApprove), «Autopilot» и др. выполняют команды без вопросов.
# Хуку режим не передают, он записан у каждого запроса в файле сессии chatSessions/<session_id>.jsonl — берём последний.
sub copilot_level {
    my ($e) = @_;
    my $id = ref $e eq 'HASH' ? ($e->{session_id} // '') : '';
    return '' unless $id =~ /^[A-Za-z0-9_-]{1,100}$/;
    my $user = "$ENV{HOME}/Library/Application Support/Code/User";
    my ($file) = grep { -f $_ } (glob("\"$user/workspaceStorage/\"*\"/chatSessions/$id.jsonl\""),
                                  "$user/globalStorage/emptyWindowChatSessions/$id.jsonl");
    return '' unless defined $file && open(my $fh, '<', $file);
    my $level = '';
    while (my $line = <$fh>) {
        $level = $1 while $line =~ /"modeInfo":\{[^{}]*"permissionLevel":"(\w+)"/g;
    }
    close $fh;
    return $level;
}

sub copilot_gated {
    my ($e) = @_;
    return 0 unless copilot_tool($e->{tool_name} // '') eq 'Bash';
    # Не обычный режим — VS Code сам решает без человека; держать команду в чёлке нельзя (21.10).
    my $level = copilot_level($e);
    return 0 if $level ne '' && $level ne 'default';
    my $command = ref $e->{tool_input} eq 'HASH' ? ($e->{tool_input}{command} // '') : '';
    $command =~ s/^\s+//;
    return 0 if $command eq '';
    my $settings = {};
    if (open(my $fh, '<', "$ENV{HOME}/Library/Application Support/Code/User/settings.json")) {
        local $/; my $text = <$fh>;
        $text =~ s{^\s*//.*$}{}mg;
        $settings = eval { JSON::PP->new->relaxed->decode($text) } // {};
        $settings = {} unless ref $settings eq 'HASH';
    }
    # VS Code разрешает всё сам — не вмешиваемся.
    return 0 if $settings->{'chat.tools.global.autoApprove'} || $settings->{'chat.tools.autoApprove'};
    # Цепочки и перенаправления VS Code проверяет по частям; такое спрашиваем всегда.
    return 1 if $command =~ /[;&|`>]|\$\(/;
    my ($first) = $command =~ /^(\S+)/;
    return 0 if grep { $_ eq $first } @COPILOT_SAFE;
    return 0 if $command =~ /^git\s+(?:status|log|diff|show|branch|remote|rev-parse|ls-files|blame|describe|tag)\b/;
    return 0 if $command =~ /^npm\s+(?:ls|list|outdated|view|info|show|explain|why|root|prefix|bin|search|help)\b/;
    my $own = ref $settings->{'chat.tools.terminal.autoApprove'} eq 'HASH' ? $settings->{'chat.tools.terminal.autoApprove'} : {};
    for my $rule (keys %$own) {
        my $value = $own->{$rule};
        $value = $value->{approve} if ref $value eq 'HASH';
        next unless $value && !ref $value;
        if ($rule =~ m{^/(.*)/([a-z]*)$}) {
            my ($pattern, $flags) = ($1, $2);
            return 0 if eval { $flags =~ /i/ ? $command =~ /$pattern/i : $command =~ /$pattern/ };
        } else {
            return 0 if $first eq $rule || index($command, "$rule ") == 0;
        }
    }
    return 1;
}

# Вопрос Copilot (AskUserQuestion: message + requestedSchema с вариантами в enum) — в формате
# вопросов Claude Code, чтобы чёлка показала ту же карточку с вариантами.
sub copilot_questions {
    my ($e) = @_;
    my $in = ref $e->{tool_input} eq 'HASH' ? $e->{tool_input} : {};
    my $schema = ref $in->{requestedSchema} eq 'HASH' ? $in->{requestedSchema} : {};
    my $props = ref $schema->{properties} eq 'HASH' ? $schema->{properties} : {};
    my @keys = ref $schema->{required} eq 'ARRAY' ? grep { ref $props->{$_} eq 'HASH' } @{ $schema->{required} } : ();
    my %seen = map { $_ => 1 } @keys;
    push @keys, grep { !$seen{$_} } sort keys %$props;
    my $message = defined $in->{message} && !ref $in->{message} ? $in->{message} : '';
    my @questions;
    for my $key (@keys) {
        my $prop = $props->{$key};
        next unless ref $prop eq 'HASH';
        my $title = defined $prop->{title} && !ref $prop->{title} ? $prop->{title} : $key;
        my @labels;
        if (ref $prop->{enum} eq 'ARRAY') { @labels = grep { defined $_ && !ref $_ } @{ $prop->{enum} }; }
        elsif (ref $prop->{oneOf} eq 'ARRAY') { @labels = map { ref $_ eq 'HASH' ? ($_->{title} // $_->{const}) : () } @{ $prop->{oneOf} }; }
        elsif (($prop->{type} // '') eq 'boolean') { @labels = ("\x{414}\x{430}", "\x{41d}\x{435}\x{442}"); } # «Да», «Нет» (скрипт без use utf8)
        my $multi = ($prop->{type} // '') eq 'array';
        if ($multi && ref $prop->{items} eq 'HASH' && ref $prop->{items}{enum} eq 'ARRAY') { @labels = @{ $prop->{items}{enum} }; }
        push @questions, { key => $key, header => $title,
                           question => (@keys == 1 && $message ne '' ? $message : $title),
                           options => [ map { { label => "$_", description => '' } } @labels ],
                           multiSelect => $multi ? JSON::PP::true : JSON::PP::false };
    }
    push @questions, { key => '', header => '', question => $message, options => [], multiSelect => JSON::PP::false }
        if !@questions && $message ne '';
    return @questions;
}

# Ответ из чёлки на вопрос Copilot. Ответить за инструмент VS Code хуку не даёт, поэтому шаг вопроса
# «отклоняем», а ответ человека кладём в причину — Copilot читает её и продолжает. Без ответа — «{}»,
# и вопрос появляется в чате VS Code, как обычно.
sub copilot_question {
    my ($e) = @_;
    my @questions = copilot_questions($e) or return '{}';
    my $t = copilot_event($e) or return '{}';
    my $answer = wait_answer({ session_id => $t->{session_id}, cwd => ($e->{cwd} // ''), tool_name => 'AskUserQuestion',
                               tool_input => { questions => [ map { my %q = %$_; delete $q{key}; \%q } @questions ] } }) or return '{}';
    my $answers = ref $answer->{answers} eq 'HASH' ? $answer->{answers} : {};
    return '{}' unless ($answer->{behavior} // '') eq 'allow' && %$answers;
    my @parts;
    for my $q (@questions) {
        my $value = $answers->{ $q->{question} };
        push @parts, ($q->{header} ne '' ? "$q->{header}: " : '') . $value if defined $value && $value ne '';
    }
    my $reason = 'The user already answered this question in Lumio (do not ask again): ' . join('; ', @parts);
    my %decision = (hookEventName => 'PreToolUse', permissionDecision => 'deny', permissionDecisionReason => $reason);
    return JSON::PP->new->utf8->canonical->encode({ permissionDecision => 'deny', permissionDecisionReason => $reason,
                                                    hookSpecificOutput => \%decision });
}

# Ответ для VS Code: «{}» — решает сам VS Code (спросит в чате, как обычно).
sub copilot_ask {
    my ($e) = @_;
    # В «Autopilot» на вопросы VS Code отвечает сам — чёлка их не держит.
    return copilot_question($e) if ref $e eq 'HASH' && ($e->{tool_name} // '') eq 'AskUserQuestion' && alive()
                                   && copilot_level($e) ne 'autopilot';
    return '{}' unless ref $e eq 'HASH' && copilot_gated($e) && alive();
    my $t = copilot_event($e) or return '{}';
    my %input;
    for my $key (qw(command description)) {
        my $value = $t->{tool_input}{$key};
        $input{$key} = substr($value, 0, 600) if defined $value && !ref $value;
    }
    my $answer = wait_answer({ session_id => $t->{session_id}, cwd => ($e->{cwd} // ''),
                               tool_name => 'Bash', tool_input => \%input }) or return '{}';
    my $behavior = $answer->{behavior} // '';
    return '{}' unless $behavior eq 'allow' || $behavior eq 'deny';
    my %decision = (hookEventName => 'PreToolUse', permissionDecision => $behavior);
    $decision{permissionDecisionReason} = ($answer->{message} // 'The user declined this in Lumio.') if $behavior eq 'deny';
    # Copilot CLI читает решение сверху, VS Code — в hookSpecificOutput.
    my %top = (permissionDecision => $behavior);
    $top{permissionDecisionReason} = $decision{permissionDecisionReason} if $decision{permissionDecisionReason};
    return JSON::PP->new->utf8->canonical->encode({ %top, hookSpecificOutput => \%decision });
}

# --- Cursor ---
# Свои названия событий и инструментов; переводим в формат Claude Code.

my (%CURSOR_EVENTS, %CURSOR_TOOLS);
BEGIN {
    %CURSOR_EVENTS = (sessionStart => 'SessionStart', beforeSubmitPrompt => 'UserPromptSubmit', preToolUse => 'PreToolUse',
                      postToolUse => 'PostToolUse', postToolUseFailure => 'PostToolUseFailure', subagentStart => 'SubagentStart',
                      subagentStop => 'SubagentStop', stop => 'Stop', sessionEnd => 'SessionEnd');
    %CURSOR_TOOLS = (Shell => 'Bash', Read => 'Read', Write => 'Write', Edit => 'Edit', StrReplace => 'Edit',
                     MultiEdit => 'Edit', ApplyPatch => 'Edit', Delete => 'Edit', EditNotebook => 'NotebookEdit',
                     Grep => 'Grep', Glob => 'Glob', LS => 'LS', SemanticSearch => 'Grep', WebSearch => 'WebSearch',
                     WebFetch => 'WebFetch', TodoWrite => 'TodoWrite', Task => 'Agent');
}

sub cursor_id {
    my ($e) = @_;
    my $id = $e->{conversation_id} // $e->{session_id} // '';
    return if ref $id;
    $id =~ s/[^A-Za-z0-9_-]//g;
    return $id eq '' ? undef : "cursor-$id";
}

sub cursor_cwd {
    my ($e) = @_;
    my $cwd = $e->{cwd};
    $cwd = $e->{workspace_roots}[0] if (!defined $cwd || ref $cwd || $cwd eq '') && ref $e->{workspace_roots} eq 'ARRAY';
    return defined $cwd && !ref $cwd ? $cwd : '';
}

# Ответ агента приходит до «stop» отдельным событием — храним его до конца хода.
sub cursor_answer_file { my ($id) = @_; return "$support/cursor/$id.answer"; }

sub cursor_event {
    my ($e) = @_;
    my $event = $e->{hook_event_name} // '';
    my $id = cursor_id($e) or return;
    if ($event eq 'afterAgentResponse') {
        my $text = $e->{text};
        return unless defined $text && !ref $text && $text ne '';
        mkdir "$support/cursor";
        if (open(my $fh, '>', cursor_answer_file($id))) {
            print $fh JSON::PP->new->utf8->encode({ text => substr($text, 0, 8000) });
            close $fh;
        }
        return;
    }
    my $name = $CURSOR_EVENTS{$event} or return;
    my %t = (session_id => $id, cwd => cursor_cwd($e), hook_event_name => $name, lumio_agent => 'cursor');
    $t{prompt} = $e->{prompt} if defined $e->{prompt} && !ref $e->{prompt};
    if ($name =~ /^Subagent/) {
        $t{agent_id} = 'cursor-helper';
        my $type = $e->{subagent_type} // $e->{agent_type};
        $t{agent_type} = $type if defined $type && !ref $type;
    }
    if ($name eq 'Stop') {
        my $status = $e->{status} // '';
        $t{hook_event_name} = 'StopFailure' if $status eq 'error';
        $t{hook_event_name} = 'TurnAborted' if $status eq 'aborted';
        my $file = cursor_answer_file($id);
        if (open(my $fh, '<', $file)) {
            local $/;
            my $saved = eval { JSON::PP->new->utf8->decode(<$fh>) };
            close $fh;
            $t{last_assistant_message} = $saved->{text} if ref $saved eq 'HASH' && defined $saved->{text};
        }
        unlink $file;
    }
    if (defined $e->{tool_name} && !ref $e->{tool_name}) {
        $t{tool_name} = $CURSOR_TOOLS{ $e->{tool_name} } // $e->{tool_name};
    }
    if (ref $e->{tool_input} eq 'HASH') {
        my $in = $e->{tool_input};
        my %out;
        for my $pair ([command => 'command'], [description => 'description'], [description => 'explanation'],
                      [file_path => 'file_path'], [file_path => 'target_file'], [file_path => 'filePath'],
                      [path => 'path'], [pattern => 'pattern'], [pattern => 'glob_pattern'], [pattern => 'query'],
                      [query => 'search_term'], [url => 'url']) {
            my ($to, $from) = @$pair;
            my $value = $in->{$from};
            $out{$to} //= $value if defined $value && !ref $value && $value ne '';
        }
        # Read и правки иногда называют файл просто «path».
        $out{file_path} //= $out{path} if ($t{tool_name} // '') =~ /^(?:Read|Write|Edit|NotebookEdit)$/;
        if (ref $in->{todos} eq 'ARRAY') {
            my @todos;
            for my $todo (@{ $in->{todos} }) {
                next unless ref $todo eq 'HASH';
                my $status = lc($todo->{status} // '');
                push @todos, { content => ($todo->{content} // ''),
                               status => $status =~ /progress/ ? 'in_progress' : $status =~ /complet|done/ ? 'completed' : 'pending' };
            }
            $out{todos} = \@todos;
        }
        $t{tool_input} = \%out;
    }
    return \%t;
}

# Настройки агента Cursor (его база состояния, только чтение).
sub cursor_settings {
    my $db = "$ENV{HOME}/Library/Application Support/Cursor/User/globalStorage/state.vscdb";
    return {} unless -e $db;
    my $key = 'src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser';
    open(my $fh, '-|', '/usr/bin/sqlite3', '-readonly', $db, "select value from ItemTable where key='$key'") or return {};
    local $/;
    my $text = <$fh> // '';
    close $fh;
    my $state = eval { JSON::PP->new->utf8->decode($text) };
    return ref $state eq 'HASH' && ref $state->{composerState} eq 'HASH' ? $state->{composerState} : {};
}

sub cursor_allowed {
    my ($command, $list) = @_;
    return 0 unless ref $list eq 'ARRAY';
    for my $rule (@$list) {
        next unless defined $rule && !ref $rule && $rule ne '';
        return 1 if $command eq $rule || index($command, "$rule ") == 0;
    }
    return 0;
}

# Мост Lumio в Cursor стоит — чёлка может нажать за человека Run или Skip.
sub cursor_bridge { my @found = glob("\"$ENV{HOME}/.cursor/extensions/lumiomac.lumio-bridge-\"*"); return scalar @found; }

# Процесс самого Cursor: хук запускает короткоживущая оболочка, поэтому поднимаемся по родителям.
sub cursor_pid {
    my $pid = getppid();
    for (1 .. 6) {
        my $name = `/bin/ps -o comm= -p $pid` // '';
        return $pid if $name =~ /Cursor/;
        my $parent = `/bin/ps -o ppid= -p $pid` // '';
        $parent =~ s/\s+//g;
        last unless $parent =~ /^\d+$/ && $parent > 1;
        $pid = $parent;
    }
    return getppid();
}

# Карточка в чёлке. Хук не ждёт ответа: Cursor уже показал свою кнопку Run, а ответ из чёлки
# Lumio передаёт мосту. pid — сам Cursor: закроют его — карточка исчезнет.
sub cursor_request {
    my ($t) = @_;
    return unless alive() && cursor_bridge();
    my $json = JSON::PP->new->utf8->canonical;
    my $request = sprintf('%s/ask/%d-%d.request.json', $support, time, $$);
    open(my $fh, '>', "$request.tmp") or return;
    print $fh $json->encode({ session_id => $t->{session_id}, cwd => $t->{cwd}, tool_name => 'Bash',
                              tool_input => { command => $t->{tool_input}{command} }, pid => cursor_pid(), ts => time });
    close $fh;
    rename("$request.tmp", $request);
}

# Команду уже выполнили или пропустили в самом Cursor — карточка в чёлке больше не нужна.
sub cursor_clear {
    my ($session) = @_;
    for my $file (glob("\"$support/ask/\"*.request.json")) {
        open(my $fh, '<', $file) or next;
        local $/;
        my $request = eval { JSON::PP->new->utf8->decode(<$fh>) };
        close $fh;
        unlink $file if ref $request eq 'HASH' && ($request->{session_id} // '') eq $session;
    }
}

# Спросит ли Cursor сам: чёлка спрашивает только об этих командах.
# Команда терминала из события: preToolUse (Shell) или beforeShellExecution.
sub cursor_command {
    my ($e) = @_;
    return $e->{command} if defined $e->{command} && !ref $e->{command};
    return unless ($e->{tool_name} // '') eq 'Shell' && ref $e->{tool_input} eq 'HASH';
    my $command = $e->{tool_input}{command};
    return defined $command && !ref $command ? $command : undef;
}

sub cursor_gated {
    my ($e) = @_;
    my $command = cursor_command($e);
    return 0 unless defined $command && !ref $command;
    $command =~ s/^\s+//;
    return 0 if $command eq '';
    # Песочница Cursor запускает команду сама, без вопроса (поле есть в beforeShellExecution).
    return 0 if $e->{sandbox};
    my $chained = $command =~ /[;&|`>]|\$\(/;
    my $perm = {};
    if (open(my $fh, '<', "$ENV{HOME}/.cursor/permissions.json")) {
        local $/;
        $perm = eval { JSON::PP->new->relaxed->decode(<$fh>) } // {};
    }
    $perm = {} unless ref $perm eq 'HASH';
    my $mode = $perm->{approvalMode} // '';
    return 0 if $mode eq 'unrestricted';
    return 1 if $mode eq 'manual';
    return 0 if !$chained && cursor_allowed($command, $perm->{terminalAllowlist});
    return 1 if $mode eq 'allowlist';
    my $state = cursor_settings();
    my ($agent) = grep { ref $_ eq 'HASH' && ($_->{id} // '') eq 'agent' } @{ ref $state->{modes4} eq 'ARRAY' ? $state->{modes4} : [] };
    $agent //= {};
    # «Запускать всё» — Cursor не спрашивает, не вмешиваемся.
    return 0 if $agent->{fullAutoRun} || $state->{yoloEnableRunEverything};
    return 0 if !$chained && cursor_allowed($command, $state->{yoloCommandAllowlist});
    # Умный режим решает сам по смыслу команды — его не угадать.
    return 0 if $agent->{autoRun} && $agent->{smartModeAutoRun};
    return 1;
}
