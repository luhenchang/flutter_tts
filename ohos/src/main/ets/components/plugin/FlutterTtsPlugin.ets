import { textToSpeech } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  Any,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult
} from '@ohos/flutter_ohos';
import HashMap from '@ohos.util.HashMap';

const CHANNEL_NAME: string = 'flutter_tts';
const TAG: string = 'FlutterTts';
const ENGINE_NAME: string = 'FlutterTts';
const MAX_SPEECH_INPUT_LENGTH: number = 10000;
const PERSON_ZH_FEMALE: number = 13;
const PERSON_ZH_FEMALE_COMPAT: number = 0;
const PERSON_ZH_MALE: number = 21;
const PERSON_EN_FEMALE: number = 8;
const LANGUAGE_ZH: string = 'zh-CN';
const LANGUAGE_EN: string = 'en-US';

export class VoiceRecord {
  language: string = '';
  person: number = 0;
  style: string = '';
  gender: string = '';
  description: string = '';
  name: string = '';
}

/**
 * HarmonyOS implementation of the flutter_tts method channel.
 * Speech playback uses Core Speech Kit textToSpeech.
 */
export default class FlutterTtsPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private engine: textToSpeech.TextToSpeechEngine | null = null;
  private createPromise: Promise<boolean> | null = null;
  private engineGeneration: number = 0;
  private engineReady: boolean = false;
  private pending: Array<() => void> = [];
  private language: string = LANGUAGE_ZH;
  private person: number = PERSON_ZH_FEMALE;
  private speed: number = 1;
  private volume: number = 1;
  private pitch: number = 1;
  private silenceMs: number = 0;
  private flutterQueueMode: number = 0;
  private awaitSpeakCompletion: boolean = false;
  private speaking: boolean = false;
  private speakResult: MethodResult | null = null;
  private pauseRequested: boolean = false;
  private requestSeq: number = 0;
  private activeRequestIds: Array<string> = [];
  private voiceRecords: Array<VoiceRecord> = [];
  private voicesLoaded: boolean = false;

  getUniqueClassName(): string {
    return 'FlutterTtsPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
    }
    this.finishSpeak(0);
    this.shutdownCurrent();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
    this.startCreate();
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.finishSpeak(0);
    this.shutdownCurrent();
    this.flushPending();
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'speak':
        this.speak(this.readSpeakText(call), result);
        break;
      case 'stop':
        this.stop(result);
        break;
      case 'pause':
        this.pause(result);
        break;
      case 'awaitSpeakCompletion':
        this.awaitSpeakCompletion = this.readBoolArg(call);
        result.success(1);
        break;
      case 'awaitSynthCompletion':
        result.success(1);
        break;
      case 'synthesizeToFile':
        result.error('not_supported', 'synthesizeToFile is not supported on HarmonyOS', null);
        break;
      case 'setLanguage':
        this.setLanguage(this.readStringArg(call), result);
        break;
      case 'setSpeechRate':
        this.setSpeechRate(this.readNumberArg(call), result);
        break;
      case 'setVolume':
        this.setVolume(this.readNumberArg(call), result);
        break;
      case 'setPitch':
        this.setPitch(this.readNumberArg(call), result);
        break;
      case 'setVoice':
        this.setVoice(call, result);
        break;
      case 'clearVoice':
        this.clearVoice(result);
        break;
      case 'getLanguages':
        this.getLanguages(result);
        break;
      case 'getVoices':
        this.getVoices(result);
        break;
      case 'getDefaultVoice':
        this.getDefaultVoice(result);
        break;
      case 'isLanguageAvailable':
        result.success(this.isLanguageAvailable(this.readStringArg(call)));
        break;
      case 'isLanguageInstalled':
        result.success(this.isLanguageInstalled(this.readStringArg(call)));
        break;
      case 'areLanguagesInstalled':
        result.success(this.areLanguagesInstalled(this.readStringList(call)));
        break;
      case 'getSpeechRateValidRange':
        result.success(this.speechRateRange());
        break;
      case 'getMaxSpeechInputLength':
        result.success(MAX_SPEECH_INPUT_LENGTH);
        break;
      case 'setSilence':
        this.silenceMs = Math.max(0, Math.floor(this.readNumberArg(call)));
        result.success(1);
        break;
      case 'setQueueMode':
        this.flutterQueueMode = this.readNumberArg(call) === 1 ? 1 : 0;
        result.success(1);
        break;
      case 'getEngines':
        result.success(['CoreSpeechKit']);
        break;
      case 'getDefaultEngine':
        result.success('CoreSpeechKit');
        break;
      case 'setEngine':
        result.success(1);
        break;
      case 'setSharedInstance':
      case 'autoStopSharedSession':
      case 'setAudioAttributesForNavigation':
      case 'setIosAudioCategory':
        result.success(1);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  private speak(text: string, result: MethodResult): void {
    if (text.trim().length === 0) {
      this.invoke('speak.onError', 'Error from TextToSpeech (speak) - empty text');
      result.success(0);
      return;
    }
    if (this.speaking && this.flutterQueueMode === 0) {
      result.success(0);
      return;
    }
    this.withEngine(() => {
      this.speakWithEngine(text, result);
    }, () => {
      this.invoke('speak.onError', 'Error from TextToSpeech (speak) - engine is unavailable');
      result.success(0);
    });
  }

  private speakWithEngine(text: string, result: MethodResult): void {
    const engine = this.engine;
    if (engine == null) {
      this.invoke('speak.onError', 'Error from TextToSpeech (speak) - engine is unavailable');
      result.success(0);
      return;
    }
    let content = text;
    if (this.silenceMs > 0) {
      content = `[p${this.silenceMs}]${text}`;
    }
    if (content.length > MAX_SPEECH_INPUT_LENGTH) {
      this.invoke('speak.onError', 'Error from TextToSpeech (speak) - text length is out of range');
      result.success(0);
      return;
    }
    const requestId = this.nextRequestId();
    this.activeRequestIds.push(requestId);
    const speakParams = this.buildSpeakParams(requestId);
    try {
      engine.speak(content, speakParams);
    } catch (err) {
      this.removeRequest(requestId);
      const error = err as BusinessError;
      const code = error != null && error.code != null ? `${error.code}` : '';
      const message = error != null && error.message != null ? error.message : `${err}`;
      this.invoke('speak.onError', `Error from TextToSpeech (speak) - ${code} ${message}`);
      result.success(0);
      return;
    }
    if (this.awaitSpeakCompletion && this.flutterQueueMode === 0) {
      this.speaking = true;
      this.speakResult = result;
    } else {
      result.success(1);
    }
  }

  private stop(result: MethodResult): void {
    this.pauseRequested = false;
    this.stopEnginePlayback();
    this.activeRequestIds = [];
    this.finishSpeak(0);
    result.success(1);
  }

  private pause(result: MethodResult): void {
    this.pauseRequested = true;
    const stopped = this.stopEnginePlayback();
    if (!stopped) {
      this.pauseRequested = false;
    }
    this.activeRequestIds = [];
    this.finishSpeak(0);
    result.success(1);
  }

  private setLanguage(language: string, result: MethodResult): void {
    const normalized = this.normalizeLanguage(language);
    if (!this.isLanguageAvailable(normalized)) {
      result.success(0);
      return;
    }
    const person = this.personForLanguage(normalized, this.person);
    if (normalized === this.language && person === this.person && this.engineReady) {
      result.success(1);
      return;
    }
    this.recreateEngine(normalized, person).then((ok: boolean) => {
      result.success(ok ? 1 : 0);
    });
  }

  private setSpeechRate(rate: number, result: MethodResult): void {
    // flutter_tts uses 0.5 as normal. Harmony speed 1 is normal and the range is [0.5, 2].
    this.speed = this.clamp(rate * 2, 0.5, 2);
    result.success(1);
  }

  private setVolume(volume: number, result: MethodResult): void {
    if (volume < 0 || volume > 1) {
      console.error(`${TAG} invalid volume ${volume}`);
      result.success(0);
      return;
    }
    // flutter_tts uses 1 as loudest. Harmony volume 1 is normal and 2 is the maximum.
    this.volume = this.clamp(volume * 2, 0, 2);
    result.success(1);
  }

  private setPitch(pitch: number, result: MethodResult): void {
    if (pitch < 0.5 || pitch > 2) {
      console.error(`${TAG} invalid pitch ${pitch}`);
      result.success(0);
      return;
    }
    this.pitch = pitch;
    result.success(1);
  }

  private setVoice(call: MethodCall, result: MethodResult): void {
    const name = this.readMapString(call, 'name');
    const locale = this.readMapString(call, 'locale');
    const identifier = this.readMapString(call, 'identifier');
    this.withEngine(() => {
      this.loadVoices().then((voices: Array<VoiceRecord>) => {
        const matched = this.findVoice(voices, name, locale, identifier);
        if (matched == null) {
          result.success(0);
          return;
        }
        const language = this.normalizeLanguage(matched.language);
        if (language === this.language && matched.person === this.person && this.engineReady) {
          result.success(1);
          return;
        }
        this.recreateEngine(language, matched.person).then((ok: boolean) => {
          result.success(ok ? 1 : 0);
        });
      });
    }, () => {
      result.success(0);
    });
  }

  private clearVoice(result: MethodResult): void {
    const person = this.defaultPerson(this.language);
    if (person === this.person && this.engineReady) {
      result.success(1);
      return;
    }
    this.recreateEngine(this.language, person).then((ok: boolean) => {
      result.success(ok ? 1 : 0);
    });
  }

  private getLanguages(result: MethodResult): void {
    this.withEngine(() => {
      this.loadVoices().then((voices: Array<VoiceRecord>) => {
        result.success(this.collectLanguages(voices));
      });
    }, () => {
      result.success([LANGUAGE_ZH, LANGUAGE_EN]);
    });
  }

  private getVoices(result: MethodResult): void {
    this.withEngine(() => {
      this.loadVoices().then((voices: Array<VoiceRecord>) => {
        const maps: Array<Record<string, string>> = [];
        for (let i = 0; i < voices.length; i++) {
          maps.push(this.voiceToMap(voices[i]));
        }
        result.success(maps);
      });
    }, () => {
      result.success(this.fallbackVoiceMaps());
    });
  }

  private getDefaultVoice(result: MethodResult): void {
    this.withEngine(() => {
      this.loadVoices().then((voices: Array<VoiceRecord>) => {
        result.success(this.voiceToMap(this.currentVoice(voices)));
      });
    }, () => {
      result.success(this.voiceToMap(this.makeVoice(this.language, this.person, '', '')));
    });
  }

  private withEngine(onReady: () => void, onFailed: () => void): void {
    if (this.engineReady && this.engine != null) {
      onReady();
      return;
    }
    this.pending.push(() => {
      if (this.engineReady && this.engine != null) {
        onReady();
      } else {
        onFailed();
      }
    });
    this.startCreate();
  }

  private recreateEngine(language: string, person: number): Promise<boolean> {
    const previousLanguage = this.language;
    const previousPerson = this.person;
    this.language = language;
    this.person = person;
    this.shutdownCurrent();
    return this.startCreate().then((ok: boolean) => {
      if (ok) {
        return true;
      }
      this.language = previousLanguage;
      this.person = previousPerson;
      this.shutdownCurrent();
      return this.startCreate().then(() => false);
    });
  }

  private startCreate(): Promise<boolean> {
    if (this.engineReady && this.engine != null) {
      return Promise.resolve(true);
    }
    if (this.createPromise != null) {
      return this.createPromise;
    }
    const generation = ++this.engineGeneration;
    const params = this.buildCreateParams();
    this.createPromise = textToSpeech.createEngine(params).then((created: textToSpeech.TextToSpeechEngine) => {
      if (generation !== this.engineGeneration) {
        try {
          created.shutdown();
        } catch (shutdownErr) {
          console.error(`${TAG} release stale engine failed: ${shutdownErr}`);
        }
        return false;
      }
      this.engine = created;
      this.attachListener();
      this.engineReady = true;
      this.createPromise = null;
      console.info(`${TAG} engine created. language=${this.language}, person=${this.person}`);
      this.flushPending();
      return true;
    }).catch((err: BusinessError) => {
      if (generation !== this.engineGeneration) {
        return false;
      }
      return this.handleCreateError(err);
    });
    return this.createPromise;
  }

  private handleCreateError(err: BusinessError): Promise<boolean> {
    const code = err != null && err.code != null ? err.code : -1;
    const message = err != null && err.message != null ? err.message : '';
    console.error(`${TAG} createEngine failed. code=${code}, message=${message}`);
    this.createPromise = null;
    this.engineReady = false;
    if (code === 1002300003 && this.person === PERSON_ZH_FEMALE) {
      this.person = PERSON_ZH_FEMALE_COMPAT;
      return this.startCreate();
    }
    this.flushPending();
    return Promise.resolve(false);
  }

  private shutdownCurrent(): void {
    const notifyCancel = this.activeRequestIds.length > 0 || this.speakResult != null;
    this.engineGeneration++;
    this.engineReady = false;
    this.createPromise = null;
    this.activeRequestIds = [];
    this.pauseRequested = false;
    this.speaking = false;
    const current = this.engine;
    this.engine = null;
    if (current != null) {
      try {
        current.shutdown();
      } catch (err) {
        console.error(`${TAG} shutdown failed: ${err}`);
      }
    }
    if (notifyCancel) {
      this.invoke('speak.onCancel', true);
      this.finishSpeak(0);
    }
  }

  private buildCreateParams(): textToSpeech.CreateEngineParams {
    const extraParam: Record<string, Object> = {
      'style': 'interaction-broadcast' as Object,
      'locate': 'CN' as Object,
      'name': ENGINE_NAME as Object
    };
    const initParams: textToSpeech.CreateEngineParams = {
      language: this.language,
      person: this.person,
      online: 1,
      extraParams: extraParam
    };
    return initParams;
  }

  private buildSpeakParams(requestId: string): textToSpeech.SpeakParams {
    const extraParam: Record<string, Object> = {
      'speed': this.speed as Object,
      'volume': this.volume as Object,
      'pitch': this.pitch as Object,
      'languageContext': this.language as Object,
      'audioType': 'pcm' as Object,
      'playType': 1 as Object,
      'soundChannel': 3 as Object,
      'queueMode': this.harmonyQueueMode() as Object
    };
    const speakParams: textToSpeech.SpeakParams = {
      requestId: requestId,
      extraParams: extraParam
    };
    return speakParams;
  }

  private harmonyQueueMode(): number {
    // flutter 0 QUEUE_FLUSH -> Harmony preempt. flutter 1 QUEUE_ADD -> Harmony queue.
    return this.flutterQueueMode === 1 ? 0 : 1;
  }

  private attachListener(): void {
    if (this.engine == null) {
      return;
    }
    const plugin = this;
    const generation = this.engineGeneration;
    const listener: textToSpeech.SpeakListener = {
      onStart(requestId: string, response: textToSpeech.StartResponse) {
        if (!plugin.isCurrentListener(generation)) {
          return;
        }
        plugin.handleStart(requestId, response);
      },
      onComplete(requestId: string, response: textToSpeech.CompleteResponse) {
        if (!plugin.isCurrentListener(generation)) {
          return;
        }
        plugin.handleComplete(requestId, response);
      },
      onStop(requestId: string, response: textToSpeech.StopResponse) {
        if (!plugin.isCurrentListener(generation)) {
          return;
        }
        plugin.handleStop(requestId, response);
      },
      onData(requestId: string, audio: ArrayBuffer, response: textToSpeech.SynthesisResponse) {
        if (!plugin.isCurrentListener(generation)) {
          return;
        }
        plugin.handleData(requestId, audio, response);
      },
      onError(requestId: string, errorCode: number, errorMessage: string) {
        if (!plugin.isCurrentListener(generation)) {
          return;
        }
        plugin.handleError(requestId, errorCode, errorMessage);
      }
    };
    this.engine.setListener(listener);
  }

  private isCurrentListener(generation: number): boolean {
    return generation === this.engineGeneration;
  }

  private handleStart(requestId: string, response: textToSpeech.StartResponse): void {
    if (!this.hasRequest(requestId)) {
      return;
    }
    console.info(`${TAG} onStart requestId=${requestId} audioType=${response.audioType}`);
    this.invoke('speak.onStart', true);
  }

  private handleComplete(requestId: string, response: textToSpeech.CompleteResponse): void {
    if (!this.hasRequest(requestId)) {
      return;
    }
    // type 0 is synthesis completion. type 1 is playback completion.
    if (response.type === 0 && this.isEngineBusy()) {
      return;
    }
    this.removeRequest(requestId);
    this.invoke('speak.onComplete', true);
    this.finishSpeak(1);
  }

  private handleStop(requestId: string, response: textToSpeech.StopResponse): void {
    const paused = this.pauseRequested;
    this.pauseRequested = false;
    this.activeRequestIds = [];
    this.speaking = false;
    if (paused) {
      this.invoke('speak.onPause', true);
    } else {
      this.invoke('speak.onCancel', true);
    }
    this.finishSpeak(0);
    if (response.message != null && requestId.length >= 0) {
      console.info(`${TAG} stop callback: ${response.message}`);
    }
  }

  private handleData(requestId: string, audio: ArrayBuffer, response: textToSpeech.SynthesisResponse): void {
    // Playback uses playType 1, which does not return an audio stream.
    if (requestId.length < 0 || audio.byteLength < 0 || response.sequence < 0) {
      return;
    }
  }

  private handleError(requestId: string, errorCode: number, errorMessage: string): void {
    if (requestId.length > 0 && !this.hasRequest(requestId)) {
      return;
    }
    this.removeRequest(requestId);
    console.error(`${TAG} onError requestId=${requestId} code=${errorCode} message=${errorMessage}`);
    this.invoke('speak.onError', `Error from TextToSpeech (speak) - ${errorCode} ${errorMessage}`);
    this.finishSpeak(0);
  }

  private loadVoices(): Promise<Array<VoiceRecord>> {
    if (this.voicesLoaded && this.voiceRecords.length > 0) {
      return Promise.resolve(this.voiceRecords);
    }
    const engine = this.engine;
    if (engine == null) {
      return Promise.resolve(this.fallbackVoices());
    }
    const query: textToSpeech.VoiceQuery = {
      requestId: this.nextRequestId(),
      online: 1
    };
    return engine.listVoices(query).then((voices: Array<textToSpeech.VoiceInfo>) => {
      const records = this.toVoiceRecords(voices);
      if (records.length === 0) {
        return this.fallbackVoices();
      }
      this.voiceRecords = records;
      this.voicesLoaded = true;
      return this.voiceRecords;
    }).catch((err: BusinessError) => {
      const code = err != null && err.code != null ? err.code : -1;
      const message = err != null && err.message != null ? err.message : '';
      console.error(`${TAG} listVoices failed. code=${code}, message=${message}`);
      return this.fallbackVoices();
    });
  }

  private toVoiceRecords(voices: Array<textToSpeech.VoiceInfo>): Array<VoiceRecord> {
    const records: Array<VoiceRecord> = [];
    for (let i = 0; i < voices.length; i++) {
      const voice = voices[i];
      const description = voice.description == null ? '' : voice.description;
      const gender = voice.gender == null ? '' : voice.gender;
      const style = voice.style == null ? 'interaction-broadcast' : voice.style;
      const language = this.normalizeLanguage(voice.language == null ? '' : voice.language);
      records.push(this.makeVoice(language, voice.person, gender, description, style));
    }
    return records;
  }

  private fallbackVoices(): Array<VoiceRecord> {
    const voices: Array<VoiceRecord> = [];
    voices.push(this.makeVoice(LANGUAGE_ZH, PERSON_ZH_FEMALE, 'Female', '聆小珊'));
    voices.push(this.makeVoice(LANGUAGE_ZH, PERSON_ZH_MALE, 'Male', '凌飞哲'));
    voices.push(this.makeVoice(LANGUAGE_EN, PERSON_EN_FEMALE, 'Female', '劳拉'));
    return voices;
  }

  private fallbackVoiceMaps(): Array<Record<string, string>> {
    const voices = this.fallbackVoices();
    const maps: Array<Record<string, string>> = [];
    for (let i = 0; i < voices.length; i++) {
      maps.push(this.voiceToMap(voices[i]));
    }
    return maps;
  }

  private makeVoice(language: string, person: number, gender: string, description: string,
    style: string = 'interaction-broadcast'): VoiceRecord {
    const voice = new VoiceRecord();
    voice.language = language;
    voice.person = person;
    voice.gender = gender;
    voice.description = description;
    voice.style = style;
    voice.name = this.buildVoiceName(language, person, description);
    return voice;
  }

  private buildVoiceName(language: string, person: number, description: string): string {
    if (description.length > 0) {
      return `${description}-${person}`;
    }
    return `${language}-${person}`;
  }

  private findVoice(voices: Array<VoiceRecord>, name: string, locale: string,
    identifier: string): VoiceRecord | null {
    const normalized = this.normalizeLanguage(locale);
    for (let i = 0; i < voices.length; i++) {
      const voice = voices[i];
      const sameLocale = normalized.length === 0 || voice.language === normalized;
      if (name.length > 0 && voice.name === name && sameLocale) {
        return voice;
      }
    }
    if (identifier.length === 0) {
      return null;
    }
    const person = Number.parseInt(identifier, 10);
    if (Number.isNaN(person)) {
      return null;
    }
    for (let i = 0; i < voices.length; i++) {
      const voice = voices[i];
      if (voice.person === person && (normalized.length === 0 || voice.language === normalized)) {
        return voice;
      }
    }
    if (normalized === LANGUAGE_ZH || normalized === LANGUAGE_EN) {
      return this.makeVoice(normalized, person, '', '');
    }
    return null;
  }

  private currentVoice(voices: Array<VoiceRecord>): VoiceRecord {
    for (let i = 0; i < voices.length; i++) {
      const voice = voices[i];
      if (voice.person === this.person && voice.language === this.language) {
        return voice;
      }
    }
    return this.makeVoice(this.language, this.person, '', '');
  }

  private voiceToMap(voice: VoiceRecord): Record<string, string> {
    const map: Record<string, string> = {
      'name': voice.name,
      'locale': voice.language,
      'gender': voice.gender,
      'identifier': `${voice.person}`,
      'quality': voice.style,
      'network_required': '0',
      'features': ''
    };
    return map;
  }

  private collectLanguages(voices: Array<VoiceRecord>): Array<string> {
    const languages: Array<string> = [];
    for (let i = 0; i < voices.length; i++) {
      const language = voices[i].language;
      if (language.length > 0 && languages.indexOf(language) < 0) {
        languages.push(language);
      }
    }
    if (languages.length === 0) {
      languages.push(LANGUAGE_ZH);
      languages.push(LANGUAGE_EN);
    }
    return languages;
  }

  private speechRateRange(): Record<string, string> {
    const range: Record<string, string> = {
      'min': '0',
      'normal': '0.5',
      'max': '1',
      'platform': 'ohos'
    };
    return range;
  }

  private isLanguageAvailable(language: string): boolean {
    const normalized = this.normalizeLanguage(language);
    return normalized === LANGUAGE_ZH || normalized === LANGUAGE_EN;
  }

  private isLanguageInstalled(language: string): boolean {
    return this.isLanguageAvailable(language);
  }

  private areLanguagesInstalled(languages: Array<string>): Record<string, boolean> {
    const installed: Record<string, boolean> = {};
    for (let i = 0; i < languages.length; i++) {
      installed[languages[i]] = this.isLanguageInstalled(languages[i]);
    }
    return installed;
  }

  private personForLanguage(language: string, currentPerson: number): number {
    if (this.personSupportsLanguage(currentPerson, language)) {
      return currentPerson;
    }
    return this.defaultPerson(language);
  }

  private personSupportsLanguage(person: number, language: string): boolean {
    if (this.voiceRecords.length > 0) {
      for (let i = 0; i < this.voiceRecords.length; i++) {
        const voice = this.voiceRecords[i];
        if (voice.person === person && voice.language === language) {
          return true;
        }
      }
      return false;
    }
    if (language === LANGUAGE_EN) {
      return person === PERSON_EN_FEMALE;
    }
    return person === PERSON_ZH_FEMALE || person === PERSON_ZH_FEMALE_COMPAT || person === PERSON_ZH_MALE;
  }

  private defaultPerson(language: string): number {
    if (language === LANGUAGE_EN) {
      return PERSON_EN_FEMALE;
    }
    return PERSON_ZH_FEMALE;
  }

  private normalizeLanguage(language: string): string {
    if (language.length === 0) {
      return '';
    }
    const value = language.replace('_', '-').toLowerCase();
    if (value === 'zh' || value.indexOf('zh-') === 0) {
      return LANGUAGE_ZH;
    }
    if (value === 'en' || value.indexOf('en-') === 0) {
      return LANGUAGE_EN;
    }
    return language.replace('_', '-');
  }

  private stopEnginePlayback(): boolean {
    const engine = this.engine;
    if (engine == null || !this.engineReady) {
      return false;
    }
    try {
      if (!engine.isBusy()) {
        return false;
      }
      engine.stop();
      return true;
    } catch (err) {
      try {
        engine.stop();
        return true;
      } catch (stopErr) {
        console.error(`${TAG} stop failed: ${stopErr}`);
        return false;
      }
    }
  }

  private isEngineBusy(): boolean {
    const engine = this.engine;
    if (engine == null) {
      return false;
    }
    try {
      return engine.isBusy();
    } catch (err) {
      return false;
    }
  }

  private finishSpeak(code: number): void {
    this.speaking = false;
    const pending = this.speakResult;
    this.speakResult = null;
    if (pending != null) {
      pending.success(code);
    }
  }

  private flushPending(): void {
    const tasks = this.pending;
    this.pending = [];
    for (let i = 0; i < tasks.length; i++) {
      tasks[i]();
    }
  }

  private invoke(method: string, args: Any): void {
    if (this.channel != null) {
      this.channel.invokeMethod(method, args);
    }
  }

  private nextRequestId(): string {
    this.requestSeq = this.requestSeq + 1;
    return `fluttertts${Date.now()}${this.requestSeq}`;
  }

  private hasRequest(requestId: string): boolean {
    return this.activeRequestIds.indexOf(requestId) >= 0;
  }

  private removeRequest(requestId: string): void {
    const index = this.activeRequestIds.indexOf(requestId);
    if (index >= 0) {
      this.activeRequestIds.splice(index, 1);
    }
  }

  private readSpeakText(call: MethodCall): string {
    if (typeof call.args === 'string') {
      return call.args as string;
    }
    const text = this.readArg(call, 'text');
    if (text == null) {
      return '';
    }
    return `${text}`;
  }

  private readStringArg(call: MethodCall): string {
    if (typeof call.args === 'string') {
      return call.args as string;
    }
    if (call.args == null) {
      return '';
    }
    return `${call.args}`;
  }

  private readNumberArg(call: MethodCall): number {
    if (typeof call.args === 'number') {
      return call.args as number;
    }
    const parsed = Number(call.args);
    if (Number.isNaN(parsed)) {
      return 0;
    }
    return parsed;
  }

  private readBoolArg(call: MethodCall): boolean {
    if (typeof call.args === 'boolean') {
      return call.args as boolean;
    }
    return `${call.args}` === 'true' || call.args === 1;
  }

  private readStringList(call: MethodCall): Array<string> {
    const languages: Array<string> = [];
    const args = call.args;
    if (args instanceof Array) {
      for (let i = 0; i < args.length; i++) {
        languages.push(`${args[i]}`);
      }
    }
    return languages;
  }

  private readMapString(call: MethodCall, key: string): string {
    const value = this.readArg(call, key);
    if (value == null) {
      return '';
    }
    return `${value}`;
  }

  private readArg(call: MethodCall, key: string): Any {
    const args = call.args;
    if (args instanceof HashMap) {
      return (args as HashMap<string, Any>).get(key);
    }
    try {
      return call.argument(key);
    } catch (err) {
      return null;
    }
  }

  private clamp(value: number, min: number, max: number): number {
    if (value < min) {
      return min;
    }
    if (value > max) {
      return max;
    }
    return value;
  }
}
