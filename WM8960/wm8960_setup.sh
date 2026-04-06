#!/bin/bash
# wm8960_setup.sh
# Standalone WM8960 Audio Board setup for Raspberry Pi 3B
# Trixie / Kernel 6.12 compatible
# No external repositories required after initial apt deps
#
# What this script does:
#   - Installs kernel build dependencies
#   - Builds and installs Waveshare's fixed WM8960 codec driver via DKMS
#   - Installs the wm8960-soundcard device tree overlay
#   - Configures /boot/firmware/config.txt
#   - Installs ALSA config and mixer state files
#   - Blacklists the conflicting soundcard module (incompatible with kernel 6.12)
#   - Disables onboard BCM audio
#   - Does NOT install the Waveshare soundcard service (causes double registration on 6.12)
#
# Usage:
#   chmod +x wm8960_setup.sh
#   sudo ./wm8960_setup.sh
#   sudo reboot

set -e

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)"
    exit 1
fi

is_Raspberry=$(cat /proc/device-tree/model | awk '{print $1}')
if [ "x${is_Raspberry}" != "xRaspberry" ]; then
    echo "This script is intended for Raspberry Pi only"
    exit 1
fi

KERNEL_VER=$(uname -r)
MOD_VER="1.0"
MOD_NAME="wm8960-soundcard"
SRC_DIR="/usr/src/${MOD_NAME}-${MOD_VER}"

echo "------------------------------------------------------"
echo "WM8960 Audio Board Setup"
echo "Kernel: ${KERNEL_VER}"
echo "------------------------------------------------------"

# --- Install dependencies ---
echo "[1/8] Installing build dependencies..."
apt-get update -qq
apt-get install -y dkms raspberrypi-kernel-headers i2c-tools

# --- Write WM8960 codec driver source (wm8960.c) ---
echo "[2/8] Writing WM8960 codec driver source..."
mkdir -p ${SRC_DIR}

cat > ${SRC_DIR}/wm8960.c << 'ENDOFFILE'
// SPDX-License-Identifier: GPL-2.0-only
/*
 * wm8960.c  --  WM8960 ALSA SoC Audio driver
 * Waveshare fixed version for Raspberry Pi
 */

#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/init.h>
#include <linux/delay.h>
#include <linux/pm.h>
#include <linux/i2c.h>
#include <linux/slab.h>
#include <sound/core.h>
#include <sound/pcm.h>
#include <sound/pcm_params.h>
#include <sound/soc.h>
#include <sound/initval.h>
#include <sound/tlv.h>
#include <sound/wm8960.h>
#include <linux/regmap.h>

#include "wm8960.h"

/* R25 - Power 1 */
#define WM8960_VMID_MASK 0x180
#define WM8960_VREF      0x40

/* R26 - Power 2 */
#define WM8960_PWR2_LOUT1	0x40
#define WM8960_PWR2_ROUT1	0x20
#define WM8960_PWR2_OUT3	0x02

/* R28 - Anti-pop 1 */
#define WM8960_POBCTRL   0x80
#define WM8960_BUFDCOPEN 0x10
#define WM8960_BUFIOEN   0x08
#define WM8960_SOFT_ST   0x04
#define WM8960_HPSTBY    0x01

/* R29 - Anti-pop 2 */
#define WM8960_DISOP     0x40
#define WM8960_DRES_MASK 0x30

static bool wm8960_volatile(struct device *dev, unsigned int reg)
{
	switch (reg) {
	case WM8960_RESET:
		return true;
	default:
		return false;
	}
}

static bool wm8960_readable(struct device *dev, unsigned int reg)
{
	switch (reg) {
	case WM8960_RESET:
		return true;
	default:
		break;
	}
	if (reg <= WM8960_PLL4)
		return true;
	return false;
}

/* enumerated controls */
static const char * const wm8960_3d_upper_cutoff[] = {"High", "Low"};
static const char * const wm8960_3d_lower_cutoff[] = {"Low", "High"};
static const char * const wm8960_alcfunc[] = {"Off", "Right", "Left", "Stereo"};
static const char * const wm8960_alcmode[] = {"ALC", "Limiter"};
static const char * const wm8960_adc_data_output_sel[] = {
	"Left Data = Left ADC;  Right Data = Right ADC",
	"Left Data = Left ADC;  Right Data = Left ADC",
	"Left Data = Right ADC; Right Data = Right ADC",
	"Left Data = Right ADC; Right Data = Left ADC",
};
static const char * const wm8960_dmonomix[] = {"Stereo", "Mono"};
static const char * const wm8960_dac_filter_characteristics[] = {"Normal", "Sloping"};

static const struct soc_enum wm8960_enum[] = {
	SOC_ENUM_SINGLE(WM8960_3D, 6, 2, wm8960_3d_upper_cutoff),
	SOC_ENUM_SINGLE(WM8960_3D, 5, 2, wm8960_3d_lower_cutoff),
	SOC_ENUM_SINGLE(WM8960_ALC1, 7, 4, wm8960_alcfunc),
	SOC_ENUM_SINGLE(WM8960_ALC3, 8, 2, wm8960_alcmode),
	SOC_ENUM_SINGLE(WM8960_ADDCTL1, 2, 4, wm8960_adc_data_output_sel),
	SOC_ENUM_SINGLE(WM8960_DACCTL1, 9, 2, wm8960_dmonomix),
	SOC_ENUM_SINGLE(WM8960_DACCTL2, 2, 2, wm8960_dac_filter_characteristics),
};

static const int deemph_settings[] = {0, 32000, 44100, 48000};

static int wm8960_set_deemph(struct snd_soc_component *component)
{
	struct wm8960_priv *wm8960 = snd_soc_component_get_drvdata(component);
	int val, i, best;

	if (wm8960->deemph) {
		best = 1;
		for (i = 2; i < ARRAY_SIZE(deemph_settings); i++) {
			if (abs(deemph_settings[i] - wm8960->lrclk) <
			    abs(deemph_settings[best] - wm8960->lrclk))
				best = i;
		}

		val = best;
	} else {
		val = 0;
	}

	dev_dbg(component->dev, "Set deemphasis %d\n", val);

	return snd_soc_component_update_bits(component, WM8960_DACCTL1,
				   0x6, val << 1);
}

static int wm8960_get_deemph(struct snd_kcontrol *kcontrol,
			     struct snd_ctl_elem_value *ucontrol)
{
	struct snd_soc_component *component = snd_soc_kcontrol_component(kcontrol);
	struct wm8960_priv *wm8960 = snd_soc_component_get_drvdata(component);

	ucontrol->value.integer.value[0] = wm8960->deemph;
	return 0;
}

static int wm8960_put_deemph(struct snd_kcontrol *kcontrol,
			     struct snd_ctl_elem_value *ucontrol)
{
	struct snd_soc_component *component = snd_soc_kcontrol_component(kcontrol);
	struct wm8960_priv *wm8960 = snd_soc_component_get_drvdata(component);
	unsigned int deemph = ucontrol->value.integer.value[0];
	int ret = 0;

	if (deemph > 1)
		return -EINVAL;

	mutex_lock(&wm8960->lock);
	if (wm8960->deemph != deemph) {
		wm8960->deemph = deemph;
		wm8960_set_deemph(component);
		ret = 1;
	}
	mutex_unlock(&wm8960->lock);

	return ret;
}

static const DECLARE_TLV_DB_SCALE(adc_tlv, -9750, 50, 1);
static const DECLARE_TLV_DB_SCALE(inpga_tlv, -1725, 75, 0);
static const DECLARE_TLV_DB_SCALE(dac_tlv, -12750, 50, 1);
static const DECLARE_TLV_DB_SCALE(out_tlv, -12100, 100, 1);
static const DECLARE_TLV_DB_SCALE(bypass_tlv, -2100, 300, 0);
static const DECLARE_TLV_DB_SCALE(lineinboost_tlv, -1500, 300, 1);
static const DECLARE_TLV_DB_RANGE(linein_tlv,
	0, 1, TLV_DB_SCALE_ITEM(0, 1300, 0),
	2, 3, TLV_DB_SCALE_ITEM(2000, 900, 0)
);
static const DECLARE_TLV_DB_SCALE(spk_tlv, -12100, 100, 1);
static const DECLARE_TLV_DB_SCALE(sidetone_tlv, -1500, 300, 0);
static const DECLARE_TLV_DB_SCALE(adcboost_tlv, 0, 2600, 0);

static const struct snd_kcontrol_new wm8960_snd_controls[] = {
SOC_DOUBLE_R_TLV("Capture Volume", WM8960_LINVOL, WM8960_RINVOL,
		 0, 63, 0, inpga_tlv),
SOC_DOUBLE_R("Capture Volume ZC Switch", WM8960_LINVOL, WM8960_RINVOL,
	6, 1, 0),
SOC_DOUBLE_R("Capture Switch", WM8960_LINVOL, WM8960_RINVOL,
	7, 1, 0),

SOC_SINGLE_TLV("Right Input Boost Mixer RINPUT3 Volume",
	       WM8960_INBMIX1, 4, 7, 0, lineinboost_tlv),
SOC_SINGLE_TLV("Left Input Boost Mixer LINPUT3 Volume",
	       WM8960_INBMIX2, 4, 7, 0, lineinboost_tlv),
SOC_SINGLE_TLV("Right Input Boost Mixer RINPUT2 Volume",
	       WM8960_INBMIX1, 1, 7, 0, lineinboost_tlv),
SOC_SINGLE_TLV("Left Input Boost Mixer LINPUT2 Volume",
	       WM8960_INBMIX2, 1, 7, 0, lineinboost_tlv),
SOC_SINGLE_TLV("Right Input Boost Mixer RINPUT1 Volume",
		WM8960_RINPATH, 4, 3, 0, linein_tlv),
SOC_SINGLE_TLV("Left Input Boost Mixer LINPUT1 Volume",
		WM8960_LINPATH, 4, 3, 0, linein_tlv),

SOC_DOUBLE_R_TLV("Playback Volume", WM8960_LDAC, WM8960_RDAC,
		 0, 255, 0, dac_tlv),

SOC_DOUBLE_R_TLV("Headphone Playback Volume", WM8960_LOUT1, WM8960_ROUT1,
		 0, 127, 0, out_tlv),
SOC_DOUBLE_R("Headphone Playback ZC Switch", WM8960_LOUT1, WM8960_ROUT1,
	7, 1, 0),

SOC_DOUBLE_R_TLV("Speaker Playback Volume", WM8960_LOUT2, WM8960_ROUT2,
		 0, 127, 0, spk_tlv),
SOC_DOUBLE_R("Speaker Playback ZC Switch", WM8960_LOUT2, WM8960_ROUT2,
	7, 1, 0),
SOC_SINGLE("Speaker DC Volume", WM8960_CLASSD3, 3, 5, 0),
SOC_SINGLE("Speaker AC Volume", WM8960_CLASSD3, 0, 5, 0),

SOC_SINGLE("PCM Playback -6dB Switch", WM8960_DACCTL1, 7, 1, 0),
SOC_ENUM("ADC Polarity", wm8960_enum[0]),
SOC_SINGLE("ADC High Pass Filter Switch", WM8960_DACCTL1, 0, 1, 0),

SOC_ENUM("DAC Polarity", wm8960_enum[1]),
SOC_SINGLE_BOOL_EXT("DAC Deemphasis Switch", 0,
		    wm8960_get_deemph, wm8960_put_deemph),

SOC_ENUM("3D Filter Upper Cut-Off", wm8960_enum[2]),
SOC_ENUM("3D Filter Lower Cut-Off", wm8960_enum[3]),
SOC_SINGLE("3D Volume", WM8960_3D, 1, 15, 0),
SOC_SINGLE("3D Switch", WM8960_3D, 0, 1, 0),

SOC_ENUM("ALC Function", wm8960_enum[4]),
SOC_SINGLE("ALC Max Gain", WM8960_ALC1, 4, 7, 0),
SOC_SINGLE("ALC Target", WM8960_ALC1, 0, 15, 0),
SOC_SINGLE("ALC Min Gain", WM8960_ALC2, 4, 7, 0),
SOC_SINGLE("ALC Hold Time", WM8960_ALC2, 0, 15, 0),
SOC_ENUM("ALC Mode", wm8960_enum[5]),
SOC_SINGLE("ALC Decay", WM8960_ALC3, 4, 15, 0),
SOC_SINGLE("ALC Attack", WM8960_ALC3, 0, 15, 0),

SOC_SINGLE("Noise Gate Threshold", WM8960_NOISEG, 3, 31, 0),
SOC_SINGLE("Noise Gate Switch", WM8960_NOISEG, 0, 1, 0),

SOC_DOUBLE_R_TLV("ADC PCM Capture Volume", WM8960_LADC, WM8960_RADC,
	0, 255, 0, adc_tlv),

SOC_SINGLE_TLV("Left Output Mixer Boost Bypass Volume",
	       WM8960_BYPASS1, 4, 7, 1, bypass_tlv),
SOC_SINGLE_TLV("Left Output Mixer LINPUT3 Volume",
	       WM8960_BYPASS1, 4, 7, 1, bypass_tlv),
SOC_SINGLE_TLV("Right Output Mixer Boost Bypass Volume",
	       WM8960_BYPASS2, 4, 7, 1, bypass_tlv),
SOC_SINGLE_TLV("Right Output Mixer RINPUT3 Volume",
	       WM8960_BYPASS2, 4, 7, 1, bypass_tlv),

SOC_ENUM("ADC Data Output Select", wm8960_enum[6]),
SOC_ENUM("DAC Mono Mix", wm8960_enum[7]),
SOC_ENUM("DAC Filter Characteristics", wm8960_enum[8]),
};

static const struct snd_kcontrol_new wm8960_lin_boost[] = {
SOC_DAPM_SINGLE("LINPUT2 Switch", WM8960_LINPATH, 6, 1, 0),
SOC_DAPM_SINGLE("LINPUT3 Switch", WM8960_LINPATH, 7, 1, 0),
SOC_DAPM_SINGLE("LINPUT1 Switch", WM8960_LINPATH, 8, 1, 0),
};

static const struct snd_kcontrol_new wm8960_lin[] = {
SOC_DAPM_SINGLE("Boost Switch", WM8960_LINPATH, 3, 1, 0),
};

static const struct snd_kcontrol_new wm8960_rin_boost[] = {
SOC_DAPM_SINGLE("RINPUT2 Switch", WM8960_RINPATH, 6, 1, 0),
SOC_DAPM_SINGLE("RINPUT3 Switch", WM8960_RINPATH, 7, 1, 0),
SOC_DAPM_SINGLE("RINPUT1 Switch", WM8960_RINPATH, 8, 1, 0),
};

static const struct snd_kcontrol_new wm8960_rin[] = {
SOC_DAPM_SINGLE("Boost Switch", WM8960_RINPATH, 3, 1, 0),
};

static const struct snd_kcontrol_new wm8960_loutput_mixer[] = {
SOC_DAPM_SINGLE("PCM Playback Switch", WM8960_LOUTMIX, 8, 1, 0),
SOC_DAPM_SINGLE("LINPUT3 Switch", WM8960_LOUTMIX, 7, 1, 0),
SOC_DAPM_SINGLE("Boost Bypass Switch", WM8960_BYPASS1, 7, 1, 0),
};

static const struct snd_kcontrol_new wm8960_routput_mixer[] = {
SOC_DAPM_SINGLE("PCM Playback Switch", WM8960_ROUTMIX, 8, 1, 0),
SOC_DAPM_SINGLE("RINPUT3 Switch", WM8960_ROUTMIX, 7, 1, 0),
SOC_DAPM_SINGLE("Boost Bypass Switch", WM8960_BYPASS2, 7, 1, 0),
};

static const struct snd_kcontrol_new wm8960_mono_out[] = {
SOC_DAPM_SINGLE("Left Switch", WM8960_MONOMIX1, 7, 1, 0),
SOC_DAPM_SINGLE("Right Switch", WM8960_MONOMIX2, 7, 1, 0),
};

static const struct snd_soc_dapm_widget wm8960_dapm_widgets[] = {
SND_SOC_DAPM_INPUT("LINPUT1"),
SND_SOC_DAPM_INPUT("RINPUT1"),
SND_SOC_DAPM_INPUT("LINPUT2"),
SND_SOC_DAPM_INPUT("RINPUT2"),
SND_SOC_DAPM_INPUT("LINPUT3"),
SND_SOC_DAPM_INPUT("RINPUT3"),

SND_SOC_DAPM_SUPPLY("MICB", WM8960_POWER1, 1, 0, NULL, 0),

SND_SOC_DAPM_MIXER("Left Boost Mixer", WM8960_POWER1, 5, 0,
		   wm8960_lin_boost, ARRAY_SIZE(wm8960_lin_boost)),
SND_SOC_DAPM_MIXER("Right Boost Mixer", WM8960_POWER1, 4, 0,
		   wm8960_rin_boost, ARRAY_SIZE(wm8960_rin_boost)),

SND_SOC_DAPM_MIXER("Left Input Mixer", WM8960_POWER3, 5, 0,
		   wm8960_lin, ARRAY_SIZE(wm8960_lin)),
SND_SOC_DAPM_MIXER("Right Input Mixer", WM8960_POWER3, 4, 0,
		   wm8960_rin, ARRAY_SIZE(wm8960_rin)),

SND_SOC_DAPM_ADC("Left ADC", "Capture", WM8960_POWER1, 3, 0),
SND_SOC_DAPM_ADC("Right ADC", "Capture", WM8960_POWER1, 2, 0),

SND_SOC_DAPM_DAC("Left DAC", "Playback", WM8960_POWER2, 8, 0),
SND_SOC_DAPM_DAC("Right DAC", "Playback", WM8960_POWER2, 7, 0),

SND_SOC_DAPM_MIXER("Left Output Mixer", WM8960_POWER3, 3, 0,
	&wm8960_loutput_mixer[0],
	ARRAY_SIZE(wm8960_loutput_mixer)),
SND_SOC_DAPM_MIXER("Right Output Mixer", WM8960_POWER3, 2, 0,
	&wm8960_routput_mixer[0],
	ARRAY_SIZE(wm8960_routput_mixer)),

SND_SOC_DAPM_PGA("LOUT1 PGA", WM8960_POWER2, 6, 0, NULL, 0),
SND_SOC_DAPM_PGA("ROUT1 PGA", WM8960_POWER2, 5, 0, NULL, 0),

SND_SOC_DAPM_PGA("Left Speaker PGA", WM8960_POWER2, 4, 0, NULL, 0),
SND_SOC_DAPM_PGA("Right Speaker PGA", WM8960_POWER2, 3, 0, NULL, 0),

SND_SOC_DAPM_PGA("Right Speaker Output", WM8960_CLASSD1, 7, 0, NULL, 0),
SND_SOC_DAPM_PGA("Left Speaker Output", WM8960_CLASSD1, 6, 0, NULL, 0),

SND_SOC_DAPM_OUTPUT("SPK_LP"),
SND_SOC_DAPM_OUTPUT("SPK_LN"),
SND_SOC_DAPM_OUTPUT("HP_L"),
SND_SOC_DAPM_OUTPUT("HP_R"),
SND_SOC_DAPM_OUTPUT("SPK_RP"),
SND_SOC_DAPM_OUTPUT("SPK_RN"),
SND_SOC_DAPM_OUTPUT("OUT3"),

SND_SOC_DAPM_MIXER("Mono Output Mixer", WM8960_POWER2, 1, 0,
	&wm8960_mono_out[0],
	ARRAY_SIZE(wm8960_mono_out)),

SND_SOC_DAPM_PGA("OUT3 PGA", WM8960_POWER2, 1, 0, NULL, 0),
};

static const struct snd_soc_dapm_route audio_paths[] = {
	{ "Left Boost Mixer", "LINPUT1 Switch", "LINPUT1" },
	{ "Left Boost Mixer", "LINPUT2 Switch", "LINPUT2" },
	{ "Left Boost Mixer", "LINPUT3 Switch", "LINPUT3" },

	{ "Left Input Mixer", "Boost Switch", "Left Boost Mixer", },
	{ "Left Input Mixer", NULL, "LINPUT1", },
	{ "Left Input Mixer", NULL, "LINPUT2" },
	{ "Left Input Mixer", NULL, "LINPUT3" },

	{ "Right Boost Mixer", "RINPUT1 Switch", "RINPUT1" },
	{ "Right Boost Mixer", "RINPUT2 Switch", "RINPUT2" },
	{ "Right Boost Mixer", "RINPUT3 Switch", "RINPUT3" },

	{ "Right Input Mixer", "Boost Switch", "Right Boost Mixer", },
	{ "Right Input Mixer", NULL, "RINPUT1", },
	{ "Right Input Mixer", NULL, "RINPUT2" },
	{ "Right Input Mixer", NULL, "RINPUT3" },

	{ "Left ADC", NULL, "Left Input Mixer" },
	{ "Right ADC", NULL, "Right Input Mixer" },

	{ "Left Output Mixer", "LINPUT3 Switch", "LINPUT3" },
	{ "Left Output Mixer", "Boost Bypass Switch", "Left Boost Mixer" },
	{ "Left Output Mixer", "PCM Playback Switch", "Left DAC" },

	{ "Right Output Mixer", "RINPUT3 Switch", "RINPUT3" },
	{ "Right Output Mixer", "Boost Bypass Switch", "Right Boost Mixer" },
	{ "Right Output Mixer", "PCM Playback Switch", "Right DAC" },

	{ "LOUT1 PGA", NULL, "Left Output Mixer" },
	{ "ROUT1 PGA", NULL, "Right Output Mixer" },

	{ "HP_L", NULL, "LOUT1 PGA" },
	{ "HP_R", NULL, "ROUT1 PGA" },

	{ "Left Speaker PGA", NULL, "Left Output Mixer" },
	{ "Right Speaker PGA", NULL, "Right Output Mixer" },

	{ "Left Speaker Output", NULL, "Left Speaker PGA" },
	{ "Right Speaker Output", NULL, "Right Speaker PGA" },

	{ "SPK_LN", NULL, "Left Speaker Output" },
	{ "SPK_LP", NULL, "Left Speaker Output" },
	{ "SPK_RN", NULL, "Right Speaker Output" },
	{ "SPK_RP", NULL, "Right Speaker Output" },

	{ "Mono Output Mixer", "Left Switch", "Left Output Mixer" },
	{ "Mono Output Mixer", "Right Switch", "Right Output Mixer" },

	{ "OUT3 PGA", NULL, "Mono Output Mixer" },
	{ "OUT3", NULL, "OUT3 PGA" },
};

static const struct reg_default wm8960_reg_defaults[] = {
	{  0x0, 0x00a7 },
	{  0x1, 0x00a7 },
	{  0x2, 0x0000 },
	{  0x3, 0x0000 },
	{  0x4, 0x0000 },
	{  0x5, 0x0008 },
	{  0x6, 0x0000 },
	{  0x7, 0x000a },
	{  0x8, 0x01c0 },
	{  0x9, 0x0000 },
	{  0xa, 0x00ff },
	{  0xb, 0x00ff },
	{ 0x10, 0x0000 },
	{ 0x11, 0x007b },
	{ 0x12, 0x0100 },
	{ 0x13, 0x0032 },
	{ 0x14, 0x0000 },
	{ 0x15, 0x00c3 },
	{ 0x16, 0x00c3 },
	{ 0x17, 0x01c0 },
	{ 0x18, 0x0000 },
	{ 0x19, 0x0000 },
	{ 0x1a, 0x0000 },
	{ 0x1b, 0x0000 },
	{ 0x1c, 0x0000 },
	{ 0x1d, 0x0000 },
	{ 0x20, 0x0100 },
	{ 0x21, 0x0100 },
	{ 0x22, 0x0050 },
	{ 0x25, 0x0050 },
	{ 0x26, 0x0000 },
	{ 0x27, 0x0000 },
	{ 0x28, 0x0000 },
	{ 0x29, 0x0000 },
	{ 0x2a, 0x0040 },
	{ 0x2b, 0x0000 },
	{ 0x2c, 0x0000 },
	{ 0x2d, 0x0050 },
	{ 0x2e, 0x0050 },
	{ 0x2f, 0x0000 },
	{ 0x30, 0x0002 },
	{ 0x31, 0x0037 },
	{ 0x32, 0x0000 },
	{ 0x33, 0x0080 },
	{ 0x34, 0x0008 },
	{ 0x35, 0x0031 },
	{ 0x36, 0x0026 },
	{ 0x37, 0x00e9 },
};

struct wm8960_priv {
	struct regmap *regmap;
	int (*set_bias_level)(struct snd_soc_component *,
			      enum snd_soc_bias_level level);
	struct snd_soc_dapm_widget *out3;
	bool deemph;
	int playback_fs;
	int lrclk;
	int bclk;
	int sysclk;
	struct wm8960_data pdata;
	struct mutex lock;
};

#define wm8960_reset(c) regmap_write(c, WM8960_RESET, 0)

static int wm8960_set_bias_level_out3(struct snd_soc_component *component,
				      enum snd_soc_bias_level level)
{
	struct wm8960_priv *wm8960 = snd_soc_component_get_drvdata(component);

	switch (level) {
	case SND_SOC_BIAS_STANDBY:
		if (snd_soc_component_get_bias_level(component) == SND_SOC_BIAS_OFF) {
			regcache_sync(wm8960->regmap);

			snd_soc_component_update_bits(component, WM8960_POWER1,
					    WM8960_VREF | WM8960_VMID_MASK, WM8960_VREF | 0x80);

			msleep(100);

			snd_soc_component_update_bits(component, WM8960_POWER1,
					    WM8960_VMID_MASK, 0x100);
		}
		break;

	case SND_SOC_BIAS_OFF:
		snd_soc_component_update_bits(component, WM8960_POWER1,
				    WM8960_VREF | WM8960_VMID_MASK, 0);
		break;

	default:
		break;
	}

	return 0;
}

static int wm8960_set_bias_level_capless(struct snd_soc_component *component,
					 enum snd_soc_bias_level level)
{
	struct wm8960_priv *wm8960 = snd_soc_component_get_drvdata(component);
	int reg;

	switch (level) {
	case SND_SOC_BIAS_PREPARE:
		switch (snd_soc_component_get_bias_level(component)) {
		case SND_SOC_BIAS_STANDBY:
			snd_soc_component_update_bits(component, WM8960_APOP1,
					    WM8960_POBCTRL | WM8960_SOFT_ST |
					    WM8960_BUFDCOPEN | WM8960_BUFIOEN,
					    WM8960_POBCTRL | WM8960_SOFT_ST |
					    WM8960_BUFDCOPEN | WM8960_BUFIOEN);

			msleep(100);

			snd_soc_component_update_bits(component, WM8960_POWER1,
					    WM8960_VREF | WM8960_VMID_MASK,
					    WM8960_VREF | 0x80);

			snd_soc_component_update_bits(component, WM8960_APOP1,
					    WM8960_POBCTRL | WM8960_SOFT_ST |
					    WM8960_BUFDCOPEN | WM8960_BUFIOEN,
					    WM8960_BUFIOEN);
			break;

		case SND_SOC_BIAS_ON:
			snd_soc_component_update_bits(component, WM8960_APOP1,
					    WM8960_POBCTRL | WM8960_SOFT_ST |
					    WM8960_BUFDCOPEN | WM8960_BUFIOEN,
					    WM8960_POBCTRL | WM8960_SOFT_ST |
					    WM8960_BUFDCOPEN | WM8960_BUFIOEN);
			break;

		default:
			break;
		}
		break;

	case SND_SOC_BIAS_STANDBY:
		reg = snd_soc_component_read(component, WM8960_POWER1);

		if (reg & WM8960_VMID_MASK) {
			snd_soc_component_update_bits(component, WM8960_APOP1,
					    WM8960_POBCTRL | WM8960_SOFT_ST |
					    WM8960_BUFDCOPEN,
					    WM8960_POBCTRL | WM8960_SOFT_ST |
					    WM8960_BUFDCOPEN);

			msleep(400);

			snd_soc_component_update_bits(component, WM8960_POWER1,
					    WM8960_VREF | WM8960_VMID_MASK, 0);

			snd_soc_component_update_bits(component, WM8960_APOP1,
					    WM8960_POBCTRL | WM8960_SOFT_ST |
					    WM8960_BUFDCOPEN | WM8960_BUFIOEN,
					    0);
		}
		break;

	default:
		break;
	}

	return 0;
}

static int wm8960_hw_params(struct snd_pcm_substream *substream,
			    struct snd_pcm_hw_params *params,
			    struct snd_soc_dai *dai)
{
	struct snd_soc_component *component = dai->component;
	struct wm8960_priv *wm8960 = snd_soc_component_get_drvdata(component);
	int ret;

	wm8960->bclk = snd_soc_params_to_bclk(params);
	if (params_channels(params) == 1)
		wm8960->bclk *= 2;

	switch (params_width(params)) {
	case 16:
		break;
	case 20:
		snd_soc_component_update_bits(component, WM8960_IFACE1, 0xc, 0x4);
		break;
	case 24:
		snd_soc_component_update_bits(component, WM8960_IFACE1, 0xc, 0x8);
		break;
	case 32:
		snd_soc_component_update_bits(component, WM8960_IFACE1, 0xc, 0xc);
		break;
	default:
		dev_err(component->dev, "unsupported width %d\n",
			params_width(params));
		return -EINVAL;
	}

	wm8960->lrclk = params_rate(params);

	dev_dbg(component->dev, "bclk=%d lrclk=%d\n",
		wm8960->bclk, wm8960->lrclk);

	ret = wm8960_configure_clocking(component);
	if (ret != 0)
		return ret;

	return wm8960_set_deemph(component);
}

static int wm8960_mute(struct snd_soc_dai *dai, int mute, int direction)
{
	struct snd_soc_component *component = dai->component;

	if (mute)
		snd_soc_component_update_bits(component, WM8960_DACCTL1, 0x8, 0x8);
	else
		snd_soc_component_update_bits(component, WM8960_DACCTL1, 0x8, 0);
	return 0;
}

static int wm8960_set_bias_level(struct snd_soc_component *component,
				 enum snd_soc_bias_level level)
{
	struct wm8960_priv *wm8960 = snd_soc_component_get_drvdata(component);
	return wm8960->set_bias_level(component, level);
}

static int wm8960_set_dai_fmt(struct snd_soc_dai *codec_dai,
		unsigned int fmt)
{
	struct snd_soc_component *component = codec_dai->component;
	u16 iface = 0;

	switch (fmt & SND_SOC_DAIFMT_MASTER_MASK) {
	case SND_SOC_DAIFMT_CBP_CFP:
		iface |= 0x0040;
		break;
	case SND_SOC_DAIFMT_CBC_CFC:
		break;
	default:
		return -EINVAL;
	}

	switch (fmt & SND_SOC_DAIFMT_FORMAT_MASK) {
	case SND_SOC_DAIFMT_I2S:
		iface |= 0x0002;
		break;
	case SND_SOC_DAIFMT_RIGHT_J:
		break;
	case SND_SOC_DAIFMT_LEFT_J:
		iface |= 0x0001;
		break;
	case SND_SOC_DAIFMT_DSP_A:
		iface |= 0x0003;
		break;
	case SND_SOC_DAIFMT_DSP_B:
		iface |= 0x0013;
		break;
	default:
		return -EINVAL;
	}

	switch (fmt & SND_SOC_DAIFMT_INV_MASK) {
	case SND_SOC_DAIFMT_NB_NF:
		break;
	case SND_SOC_DAIFMT_NB_IF:
		iface |= 0x0080;
		break;
	case SND_SOC_DAIFMT_IB_NF:
		iface |= 0x0040;
		break;
	case SND_SOC_DAIFMT_IB_IF:
		iface |= 0x00C0;
		break;
	default:
		return -EINVAL;
	}

	snd_soc_component_write(component, WM8960_IFACE1, iface);
	return 0;
}

static struct {
	int div;
	int val;
} wm8960_srate[] = {
	{ 12000000, 0x0 }, { 11289600, 0x1 }, { 12288000, 0x2 },
	{ 8192000, 0x3 }, { 11289600, 0x4 }, { 12288000, 0x5 },
};

static int wm8960_configure_clocking(struct snd_soc_component *component)
{
	struct wm8960_priv *wm8960 = snd_soc_component_get_drvdata(component);
	int sysclk, bclk, lrclk, i;
	int saved_sysclk = wm8960->sysclk;

	/*
	 * If we have MCLK configured use it, otherwise try to use
	 * the PLL to derive the system clock from BCLK.
	 */
	if (wm8960->sysclk) {
		sysclk = wm8960->sysclk;
	} else {
		/* Use PLL, derive from BCLK */
		bclk = wm8960->bclk;
		lrclk = wm8960->lrclk;

		/* Try to find a sysclk that works */
		sysclk = 11289600;
		if (lrclk == 48000 || lrclk == 32000 || lrclk == 16000 ||
		    lrclk == 8000)
			sysclk = 12288000;

		/* Configure PLL to generate sysclk from bclk */
		wm8960_set_pll(component, bclk, sysclk);
	}

	/* sysclk dividers */
	for (i = 0; i < ARRAY_SIZE(wm8960_srate); i++) {
		if (wm8960_srate[i].div == sysclk) {
			snd_soc_component_update_bits(component,
					    WM8960_CLOCK1,
					    0xe0, wm8960_srate[i].val << 5);
			break;
		}
	}

	snd_soc_component_update_bits(component, WM8960_CLOCK1, 1,
			    (sysclk > 12000000) ? 1 : 0);

	wm8960->sysclk = saved_sysclk;

	return 0;
}

static int wm8960_set_pll(struct snd_soc_component *component,
			  int freq_in, int freq_out)
{
	u64 Kpart;
	unsigned int K, Ndiv, Nmod;
	unsigned int pll_freqs[2];
	int i;

	if (freq_in == 0 || freq_out == 0) {
		snd_soc_component_update_bits(component, WM8960_CLOCK1,
				    0x1, 0);
		snd_soc_component_update_bits(component, WM8960_POWER2,
				    0x1, 0);
		return 0;
	}

	/* Enable PLL */
	snd_soc_component_update_bits(component, WM8960_POWER2, 0x1, 0x1);
	snd_soc_component_update_bits(component, WM8960_CLOCK1, 0x1, 0x1);

	/* Calculate PLL settings */
	Ndiv = freq_out / freq_in;

	if (Ndiv < 6) {
		freq_in /= 2;
		snd_soc_component_update_bits(component, WM8960_PLL1, 0x10, 0x10);
		Ndiv = freq_out / freq_in;
	} else {
		snd_soc_component_update_bits(component, WM8960_PLL1, 0x10, 0);
	}

	if (Ndiv < 6 || Ndiv > 12) {
		dev_warn(component->dev,
			 "WM8960 N=%d not supported, PLL will not lock\n", Ndiv);
	}

	Nmod = freq_out % freq_in;
	Kpart = ULLONG_MAX / freq_in;
	Kpart *= Nmod;
	K = Kpart & 0xFFFFFF;

	if ((Kpart & 0xF0000000) >= 0x80000000)
		K += 2;
	else if ((Kpart & 0xF0000000) >= 0x10000000)
		K += 1;

	snd_soc_component_write(component, WM8960_PLL1, (Ndiv << 5) | 0x5);
	snd_soc_component_write(component, WM8960_PLL2, (K >> 16) & 0xFF);
	snd_soc_component_write(component, WM8960_PLL3, (K >> 8) & 0xFF);
	snd_soc_component_write(component, WM8960_PLL4, K & 0xFF);

	return 0;
}

static int wm8960_set_sysclk(struct snd_soc_dai *dai, int clk_id,
			     unsigned int freq, int dir)
{
	struct snd_soc_component *component = dai->component;
	struct wm8960_priv *wm8960 = snd_soc_component_get_drvdata(component);

	switch (clk_id) {
	case WM8960_SYSCLK_MCLK:
		snd_soc_component_update_bits(component, WM8960_CLOCK1,
				    0x1, 0);
		wm8960->sysclk = freq;
		break;
	case WM8960_SYSCLK_PLL:
		snd_soc_component_update_bits(component, WM8960_CLOCK1,
				    0x1, 0x1);
		wm8960->sysclk = freq;
		break;
	case WM8960_SYSCLK_AUTO:
		wm8960->sysclk = 0;
		break;
	default:
		return -EINVAL;
	}

	dev_dbg(component->dev, "sysclk is %dHz\n", freq);

	return 0;
}

static int wm8960_set_dai_pll(struct snd_soc_dai *codec_dai, int pll_id,
			      int source, unsigned int freq_in, unsigned int freq_out)
{
	struct snd_soc_component *component = codec_dai->component;

	return wm8960_set_pll(component, freq_in, freq_out);
}

static int wm8960_set_dai_clkdiv(struct snd_soc_dai *codec_dai,
				 int div_id, int div)
{
	struct snd_soc_component *component = codec_dai->component;
	u16 reg;

	switch (div_id) {
	case WM8960_SYSCLKDIV:
		reg = snd_soc_component_read(component, WM8960_CLOCK1) & 0x1f9;
		snd_soc_component_write(component, WM8960_CLOCK1, reg | div);
		break;
	case WM8960_DACDIV:
		reg = snd_soc_component_read(component, WM8960_CLOCK1) & 0x1c7;
		snd_soc_component_write(component, WM8960_CLOCK1, reg | div);
		break;
	case WM8960_OPCLKDIV:
		reg = snd_soc_component_read(component, WM8960_PLL1) & 0x03f;
		snd_soc_component_write(component, WM8960_PLL1, reg | div);
		break;
	case WM8960_DCLKDIV:
		reg = snd_soc_component_read(component, WM8960_CLOCK2) & 0x03f;
		snd_soc_component_write(component, WM8960_CLOCK2, reg | div);
		break;
	case WM8960_TOCLKSEL:
		reg = snd_soc_component_read(component, WM8960_ADDCTL1) & 0x1fd;
		snd_soc_component_write(component, WM8960_ADDCTL1, reg | div);
		break;
	default:
		return -EINVAL;
	}

	return 0;
}

static int wm8960_component_probe(struct snd_soc_component *component)
{
	struct wm8960_priv *wm8960 = snd_soc_component_get_drvdata(component);
	struct wm8960_data *pdata = &wm8960->pdata;
	int ret;

	wm8960->set_bias_level = wm8960_set_bias_level_out3;

	if (pdata->capless)
		wm8960->set_bias_level = wm8960_set_bias_level_capless;

	ret = wm8960_reset(wm8960->regmap);
	if (ret != 0) {
		dev_err(component->dev, "Failed to issue reset\n");
		return ret;
	}

	snd_soc_component_update_bits(component, WM8960_POWER1,
			    WM8960_VREF | WM8960_VMID_MASK, WM8960_VREF | 0x180);

	if (pdata->shared_lrclk)
		snd_soc_component_update_bits(component, WM8960_ADDCTL2,
				    0x4, 0x4);

	return 0;
}

static const struct snd_soc_dai_ops wm8960_dai_ops = {
	.hw_params	= wm8960_hw_params,
	.mute_stream	= wm8960_mute,
	.set_fmt	= wm8960_set_dai_fmt,
	.set_clkdiv	= wm8960_set_dai_clkdiv,
	.set_pll	= wm8960_set_dai_pll,
	.set_sysclk	= wm8960_set_sysclk,
	.no_capture_mute = 1,
};

static struct snd_soc_dai_driver wm8960_dai = {
	.name = "wm8960-hifi",
	.playback = {
		.stream_name = "Playback",
		.channels_min = 1,
		.channels_max = 2,
		.rates = WM8960_RATES,
		.formats = WM8960_FORMATS,},
	.capture = {
		.stream_name = "Capture",
		.channels_min = 1,
		.channels_max = 2,
		.rates = WM8960_RATES,
		.formats = WM8960_FORMATS,},
	.ops = &wm8960_dai_ops,
	.symmetric_rate = 1,
};

static const struct snd_soc_component_driver soc_component_dev_wm8960 = {
	.probe			= wm8960_component_probe,
	.set_bias_level		= wm8960_set_bias_level,
	.controls		= wm8960_snd_controls,
	.num_controls		= ARRAY_SIZE(wm8960_snd_controls),
	.dapm_widgets		= wm8960_dapm_widgets,
	.num_dapm_widgets	= ARRAY_SIZE(wm8960_dapm_widgets),
	.dapm_routes		= audio_paths,
	.num_dapm_routes	= ARRAY_SIZE(audio_paths),
	.suspend_bias_off	= 1,
	.idle_bias_on		= 1,
	.use_pmdown_time	= 1,
	.endianness		= 1,
};

static const struct regmap_config wm8960_regmap = {
	.reg_bits = 7,
	.val_bits = 9,
	.max_register = WM8960_PLL4,
	.reg_defaults = wm8960_reg_defaults,
	.num_reg_defaults = ARRAY_SIZE(wm8960_reg_defaults),
	.cache_type = REGCACHE_MAPLE,
	.volatile_reg = wm8960_volatile,
	.readable_reg = wm8960_readable,
};

static int wm8960_i2c_probe(struct i2c_client *i2c)
{
	struct wm8960_data *pdata = dev_get_platdata(&i2c->dev);
	struct wm8960_priv *wm8960;
	int ret;

	wm8960 = devm_kzalloc(&i2c->dev, sizeof(struct wm8960_priv),
			      GFP_KERNEL);
	if (wm8960 == NULL)
		return -ENOMEM;

	mutex_init(&wm8960->lock);

	wm8960->regmap = devm_regmap_init_i2c(i2c, &wm8960_regmap);
	if (IS_ERR(wm8960->regmap))
		return PTR_ERR(wm8960->regmap);

	if (pdata)
		memcpy(&wm8960->pdata, pdata, sizeof(struct wm8960_data));

	i2c_set_clientdata(i2c, wm8960);

	ret = devm_snd_soc_register_component(&i2c->dev,
			&soc_component_dev_wm8960, &wm8960_dai, 1);

	return ret;
}

static const struct i2c_device_id wm8960_i2c_id[] = {
	{ "wm8960", 0 },
	{ }
};
MODULE_DEVICE_TABLE(i2c, wm8960_i2c_id);

static const struct of_device_id wm8960_of_match[] = {
	{ .compatible = "wlf,wm8960", },
	{ }
};
MODULE_DEVICE_TABLE(of, wm8960_of_match);

static struct i2c_driver wm8960_i2c_driver = {
	.driver = {
		.name = "wm8960",
		.of_match_table = wm8960_of_match,
	},
	.probe = wm8960_i2c_probe,
	.id_table = wm8960_i2c_id,
};

module_i2c_driver(wm8960_i2c_driver);

MODULE_DESCRIPTION("ASoC WM8960 driver - Waveshare fixed version");
MODULE_AUTHOR("Waveshare");
MODULE_LICENSE("GPL");
ENDOFFILE

# --- Write wm8960.h ---
cat > ${SRC_DIR}/wm8960.h << 'ENDOFFILE'
/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef _WM8960_H
#define _WM8960_H

#define WM8960_LINVOL    0x0
#define WM8960_RINVOL    0x1
#define WM8960_LOUT1     0x2
#define WM8960_ROUT1     0x3
#define WM8960_CLOCK1    0x4
#define WM8960_DACCTL1   0x5
#define WM8960_DACCTL2   0x6
#define WM8960_IFACE1    0x7
#define WM8960_CLOCK2    0x8
#define WM8960_IFACE2    0x9
#define WM8960_LDAC      0xa
#define WM8960_RDAC      0xb
#define WM8960_RESET     0xf
#define WM8960_3D        0x10
#define WM8960_ALC1      0x11
#define WM8960_ALC2      0x12
#define WM8960_ALC3      0x13
#define WM8960_NOISEG    0x14
#define WM8960_LADC      0x15
#define WM8960_RADC      0x16
#define WM8960_ADDCTL1   0x17
#define WM8960_ADDCTL2   0x18
#define WM8960_POWER1    0x19
#define WM8960_POWER2    0x1a
#define WM8960_ADDCTL3   0x1b
#define WM8960_APOP1     0x1c
#define WM8960_APOP2     0x1d
#define WM8960_LINPATH   0x20
#define WM8960_RINPATH   0x21
#define WM8960_LOUTMIX   0x22
#define WM8960_ROUTMIX   0x25
#define WM8960_MONOMIX1  0x26
#define WM8960_MONOMIX2  0x27
#define WM8960_LOUT2     0x28
#define WM8960_ROUT2     0x29
#define WM8960_MONOOUT   0x2a
#define WM8960_INBMIX1   0x2b
#define WM8960_INBMIX2   0x2c
#define WM8960_BYPASS1   0x2d
#define WM8960_BYPASS2   0x2e
#define WM8960_POWER3    0x2f
#define WM8960_ADDCTL4   0x30
#define WM8960_CLASSD1   0x31
#define WM8960_CLASSD3   0x33
#define WM8960_PLL1      0x34
#define WM8960_PLL2      0x35
#define WM8960_PLL3      0x36
#define WM8960_PLL4      0x37

#define WM8960_SYSCLK_MCLK 1
#define WM8960_SYSCLK_PLL  2
#define WM8960_SYSCLK_AUTO 3

#define WM8960_SYSCLKDIV 1
#define WM8960_DACDIV    2
#define WM8960_OPCLKDIV  3
#define WM8960_DCLKDIV   4
#define WM8960_TOCLKSEL  5
#define WM8960_SYSCLK_DIV_1 (0 << 1)
#define WM8960_SYSCLK_DIV_2 (2 << 1)

#define WM8960_SYSCLK_DIV 2

#define WM8960_DAC_DIV_1  (0 << 3)
#define WM8960_DAC_DIV_1_5 (1 << 3)
#define WM8960_DAC_DIV_2  (2 << 3)
#define WM8960_DAC_DIV_3  (3 << 3)
#define WM8960_DAC_DIV_4  (4 << 3)
#define WM8960_DAC_DIV_5_5 (5 << 3)
#define WM8960_DAC_DIV_6  (6 << 3)

#define WM8960_DCLK_DIV_1_5 (0 << 6)
#define WM8960_DCLK_DIV_2   (1 << 6)
#define WM8960_DCLK_DIV_3   (2 << 6)
#define WM8960_DCLK_DIV_4   (3 << 6)
#define WM8960_DCLK_DIV_6   (4 << 6)
#define WM8960_DCLK_DIV_8   (5 << 6)
#define WM8960_DCLK_DIV_12  (6 << 6)
#define WM8960_DCLK_DIV_16  (7 << 6)

#define WM8960_RATES (SNDRV_PCM_RATE_8000 | SNDRV_PCM_RATE_11025 |\
		SNDRV_PCM_RATE_16000 | SNDRV_PCM_RATE_22050 | \
		SNDRV_PCM_RATE_32000 | SNDRV_PCM_RATE_44100 | \
		SNDRV_PCM_RATE_48000)

#define WM8960_FORMATS (SNDRV_PCM_FMTBIT_S16_LE | SNDRV_PCM_FMTBIT_S20_3LE |\
		SNDRV_PCM_FMTBIT_S24_LE | SNDRV_PCM_FMTBIT_S32_LE)

static int wm8960_set_pll(struct snd_soc_component *component,
			  int freq_in, int freq_out);
static int wm8960_configure_clocking(struct snd_soc_component *component);

#endif
ENDOFFILE

# --- Write Makefile ---
cat > ${SRC_DIR}/Makefile << 'ENDOFFILE'
obj-m := snd-soc-wm8960.o
snd-soc-wm8960-objs := wm8960.o
ENDOFFILE

# --- Write dkms.conf ---
cat > ${SRC_DIR}/dkms.conf << 'ENDOFFILE'
PACKAGE_NAME="wm8960-soundcard"
PACKAGE_VERSION="1.0"
BUILT_MODULE_NAME[0]="snd-soc-wm8960"
DEST_MODULE_LOCATION[0]="/updates/dkms"
AUTOINSTALL="yes"
ENDOFFILE

# --- Build and install via DKMS ---
echo "[3/8] Building WM8960 codec driver via DKMS..."

# Remove any existing install
if dkms status | grep -q "wm8960-soundcard"; then
    dkms remove --force -m wm8960-soundcard -v ${MOD_VER} --all || true
fi

dkms add -m wm8960-soundcard -v ${MOD_VER}
dkms build ${KERNEL_VER} -m wm8960-soundcard -v ${MOD_VER}
dkms install --force ${KERNEL_VER} -m wm8960-soundcard -v ${MOD_VER}

# --- Install device tree overlay ---
echo "[4/8] Installing device tree overlay..."

# The stock wm8960-soundcard.dtbo is already in /boot/firmware/overlays/
# on Trixie with Raspberry Pi kernel - verify it exists
if [ ! -f /boot/firmware/overlays/wm8960-soundcard.dtbo ]; then
    echo "ERROR: wm8960-soundcard.dtbo not found in /boot/firmware/overlays/"
    echo "Please ensure raspberrypi-kernel is installed"
    exit 1
fi
echo "Device tree overlay already present: /boot/firmware/overlays/wm8960-soundcard.dtbo"

# --- Configure config.txt ---
echo "[5/8] Configuring /boot/firmware/config.txt..."

# Disable onboard BCM audio
sed -i 's/^dtparam=audio=on/#dtparam=audio=on/' /boot/firmware/config.txt

# Enable I2C if not already
grep -q "dtparam=i2c_arm=on" /boot/firmware/config.txt || \
    sed -i 's/#dtparam=i2c_arm=on/dtparam=i2c_arm=on/' /boot/firmware/config.txt
grep -q "^dtparam=i2c_arm=on" /boot/firmware/config.txt || \
    echo "dtparam=i2c_arm=on" >> /boot/firmware/config.txt

# Add wm8960 overlay if not present
grep -q "^dtoverlay=wm8960-soundcard" /boot/firmware/config.txt || \
    echo "dtoverlay=wm8960-soundcard" >> /boot/firmware/config.txt

# Remove any stale clock overlays from previous attempts
sed -i '/dtoverlay=gpio-clock/d' /boot/firmware/config.txt
sed -i '/dtoverlay=i2s-mmap/d' /boot/firmware/config.txt
sed -i '/dtparam=i2s=on/d' /boot/firmware/config.txt

# --- Blacklist conflicting soundcard module ---
echo "[6/8] Blacklisting incompatible soundcard module..."
cat > /etc/modprobe.d/blacklist-wm8960-soundcard.conf << 'ENDOFFILE'
# wm8960-soundcard module is incompatible with kernel 6.12 built-in simple-card driver
blacklist snd_soc_wm8960_soundcard
ENDOFFILE

# Also blacklist onboard BCM audio
cat > /etc/modprobe.d/blacklist-bcm2835-audio.conf << 'ENDOFFILE'
# Disable onboard Pi audio to prevent conflict with WM8960
blacklist snd_bcm2835
ENDOFFILE

# --- Install ALSA config ---
echo "[7/8] Installing ALSA config..."
mkdir -p /etc/wm8960-soundcard

cat > /etc/wm8960-soundcard/asound.conf << 'ENDOFFILE'
pcm.!default {
  type asym
  capture.pcm "mic"
  playback.pcm "speaker"
}
pcm.mic {
  type plug
  slave {
    pcm "hw:0,0"
    rate 16000
    channels 2
    format S32_LE
  }
}
pcm.speaker {
  type plug
  slave {
    pcm "hw:0,0"
    rate 16000
    channels 2
    format S32_LE
  }
}
ENDOFFILE

# Symlink to /etc/asound.conf
rm -f /etc/asound.conf
ln -s /etc/wm8960-soundcard/asound.conf /etc/asound.conf

# --- Clean up /etc/modules ---
echo "[8/8] Cleaning up /etc/modules..."
sed -i '/snd-soc-wm8960/d' /etc/modules 2>/dev/null || true
sed -i '/snd-soc-wm8960-soundcard/d' /etc/modules 2>/dev/null || true

echo ""
echo "------------------------------------------------------"
echo "WM8960 setup complete."
echo ""
echo "Hardware notes:"
echo "  - P1 jumper: leave ALL THREE HOLES EMPTY (no jumper)"
echo "  - GPIO 4 (Pin 7): NOT connected"
echo "  - MCLK is derived internally from BCLK via WM8960 PLL"
echo ""
echo "Wiring:"
echo "  VCC  -> Pi Pin 1  (3.3V)"
echo "  GND  -> Pi Pin 6  (GND)"
echo "  SDA  -> Pi Pin 3  (GPIO 2)"
echo "  SCL  -> Pi Pin 5  (GPIO 3)"
echo "  CLK  -> Pi Pin 12 (GPIO 18)"
echo "  WS   -> Pi Pin 35 (GPIO 19)"
echo "  TXSDA-> Pi Pin 40 (GPIO 21)"
echo "  RXSDA-> Pi Pin 38 (GPIO 20)"
echo ""
echo "After reboot, test with:"
echo "  aplay -D hw:0,0 -f S32_LE -r 16000 -c 2 <file.wav>"
echo "  arecord -D hw:0,0 -f S32_LE -r 16000 -c 2 -d 5 test.wav"
echo "------------------------------------------------------"
echo "Please reboot now: sudo reboot"
