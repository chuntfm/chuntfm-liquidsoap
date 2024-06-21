#!/usr/bin/liquidsoap

%include "10-settings.liq"
%include "20-prometheus.liq"
%include "30-formats.liq"
%include "60-core.liq"

#############################
# Define all inputs sources #
#############################

input_sources = list.map(mk_source_mp3, input_list)
replay_sources = list.map(mk_replay_source,input_list_restream)
#replay_sources = list.map(mk_replay_source_from_file, input_list_restream_files)
#input_sources = list.append(input_sources, replay_sources)
randomjingle = single("./jingle/jinglevc.wav")



print("input_sources: " ^ string(input_sources))
stream_source = list.hd(list.filter(fun(s) -> s.name == "stream", input_sources))
#print("stream_source is:")
#print(stream_source.source.is_ready())
# Define safe_blank input and its metrics
safe_blank = blank(id="safe_blank")
safe_blank = source_tag(safe_blank, "safe_blank")
set_safe_blank_is_playing_metric =
  create_is_playing_metric(label_values=[radio_name,"input","safe_blank"])

real_live_source = ref("")


# Inputs bypassing the whole radio system since we don't care about monitoring jukebox and teststream
livetest = input.harbor("streamtest",port=42600,password=environment.get("LS_STREAM_PASSWORD"),buffer=8.,max=10.)
livetest = buffer(mksafe(livetest))
jukebox = input.harbor("juke",port=8001,password=environment.get("LS_JUKEBOX_PASSWORD"),buffer=2.)
jukebox = buffer(mksafe(jukebox))

# get the livesourcestate on disk if it exist
if file.exists(livesource_state_path) then
  content = file.contents(livesource_state_path)
  # check that the livesource exist in input list
  if list.exists(fun (s) -> s.name == content, input_sources) then
    preferred_live_source := content
  end
end

def is_playing(n) =
  fun () -> n == preferred_live_source()
end

def mk_switch_source(s) =
  log("mk_switch_source: #{s}")
  (is_playing(s.name), s.source)
end


#def crossfade(a,b)
#  print("crossfade with sources:")
#  print(string(a))
#  print(string(b))
#  s = if going_to_live() then
#    print("going to live")
#    #add(normalize=false,
#    #    [ sequence([ blank(duration=2.),
#    #      fade.in(duration=5.,b) ]),
#    #      fade.out(duration=5.,a) ])
#    randomjingle = single("/jingles/chuntFMjingleFuture.mp3")
#    add(normalize=false,
#    [sequence([fade.out(duration=5.,a), randomjingle, fade.in(duration=5.,b)])
#    ])
#  else
#    print("not going to live")
#    #randomjingle = playlist.once("/jingles")
#    randomjingle = single("/jingles/chuntFMjingleFuture.mp3")
#    #add(normalize=false,
#    #[ sequence([randomjingle, blank()]),
#    #  sequence([ blank(duration=5.),
#    #  fade.in(duration=7.,b) ])])
#    add(normalize=false,
#    [ sequence([randomjingle, fade.in(duration=5.,b)]) ])
#  end
#  s
#end

#def tolive(a,b)
#  print("going to live")
# 
#  add(normalize=false, [
#    sequence([fade.out(duration=5.,type="sin",a)]),
#    sequence([blank(duration=5.), once(randomjingle)]),
#    sequence([blank(duration=8.),fade.in(duration=5.,type="sin",b) ])
#  ])
#  
#end

#randomjingle = playlist.once("/jingles")
#
#    jingle_duration = source.duration(randomjingle)
#    print("jingle duration: " ^ string(jingle_duration))
#    
#
#
#    sequence([randomjingle,fade.in(duration=3.,type="sin",b) ])
def log_source_id(pair) =
  source = snd(pair)
  log(source.id())
end

log("Live switch sources:")
list.iter(log_source_id, list.map(mk_switch_source, input_sources))

live = switch(
  id="switch_live",
  track_sensitive=false,
  list.map(mk_switch_source, input_sources)
)

live = limit(normalize(live))

def mk_fallback_source(result, s) =
  log("mk_fallback_source out of: #{s}")
  if s.is_autofallback then
    [...result, (s.source:source(audio=pcm))]
  else
    result
  end
end

def tolive(a,b)
  print("inside tolive, passed sources are " ^ source.id(a) ^ " and " ^ source.id(b))
  sourcestring = string(source.id(a))
  if string.contains(substring="restream",sourcestring) then
    add(normalize=false, [
      sequence([fade.out(duration=4.,type="sin",a)]),
      sequence([blank(duration=4.5),once(single(jingle_vc_path))]),
      sequence([blank(duration=8.7),fade.in(duration=1.7,type="sin",b)])
    ])
  else
    add(normalize=false, [
      sequence([fade.out(duration=2.,type="sin",a)]),
      sequence([blank(duration=4.),fade.in(duration=1.7,type="sin",b)])
    ])
  end
end


def tojingle(a,b)
  print("inside tojingle, passed sources are " ^ source.id(a) ^ " and " ^ source.id(b))
  sequence([a, blank(duration=1.7),b])
end


def torestream(a,b)
  print("inside torestream, passed sources are " ^ source.id(a) ^ " and " ^ source.id(b))
  add(normalize=false,[
    sequence([
      fade.in(duration=1.7,type="sin",b)
    ])
  ])
end

def tosilence(a,b)
  print("inside tosilence, passed sources are " ^ source.id(a) ^ " and " ^ source.id(b))
  add(normalize=false,[
    sequence([
      fade.out(duration=1.7,type="sin",a),
      fade.in(duration=1.7,type="sin",b)
    ])
  ])

end


radio_prod = 
  fallback(
  id="fallback_prod",
  track_sensitive=false,
  transition_length=25.,
  transitions=[tolive, tojingle, torestream, tosilence],
  [
    (live:source(audio=pcm)), jingle_queue,
    ...list.fold(mk_fallback_source, [], replay_sources),
    (safe_blank:source(audio=pcm))
  ]
)

# Create the several latency time series for the output
latency_metrics_create(label_values=[radio_name,"output","radio_prod"],radio_prod)

# Create is_ready and duration_unready_seconds time series for the output and
# update them recurrently.
is_ready_metric_set =
  is_ready_metric_create(label_values=[radio_name,"output","radio_prod"])

duration_unready_seconds_metric_increase =
  duration_unready_seconds_metric_create(label_values=[radio_name,"output","radio_prod"])

is_preferred_livesource_set =
  is_preferred_livesource_metric(label_values=[radio_name,"output","radio_prod"])

thread.run(
  every=1.,
  update_source_metrics(
    is_ready_metric_set,
    duration_unready_seconds_metric_increase,
    is_preferred_livesource_set,
    "radio_prod",
    radio_prod
  )
)

# Update is_playing metrics at each metadata change
def update_is_playing_metrics(metadata) =
  source_tag = list.assoc(default="", "source_tag", metadata)

  def update_metric(s) =
    if s.name == source_tag then
      real_live_source := s.name
      s.set_is_playing_metric(1.)
    else
      s.set_is_playing_metric(0.)
    end
  end

  sources = [
    ...input_sources,
    {name                  = "safe_blank",
     is_autofallback       = true,
     is_ready              = safe_blank.is_ready,
     set_is_playing_metric = set_safe_blank_is_playing_metric,
     source                = safe_blank}
  ]

  list.iter(update_metric, sources)
end

radio_prod.on_metadata(update_is_playing_metrics)

# Detect blank before output

is_blank = ref(false)

is_blank_metric_set =
  is_blank_metric_create(label_values=[radio_name,"output","radio_prod"])

def noise_detect_handler() =
  is_blank := false
  is_blank_metric_set(0.0)
end

def blank_detect_handler() =
  is_blank := true
  is_blank_metric_set(1.0)
end

radio_prod =
  blank.detect(
    id="on_blank_radio_prod",
    max_blank=5.0,
    min_noise=0.0,
    on_noise=noise_detect_handler,
    start_blank=false,
    threshold=-40.0,
    track_sensitive=true,
    blank_detect_handler,
    radio_prod
  )

# Output LUFS analysis to prometheus metrics
set_metric_audio_lufs =
  audit_lufs_metric_create(label_values=[radio_name,"output", "radio_prod"])

radio_prod = lufs(window=5., radio_prod)

thread.run(
  every=5.,
  {set_metric_audio_lufs(radio_prod.lufs())}
)

%include "80-outputs.liq"
%include "90-http.liq"


