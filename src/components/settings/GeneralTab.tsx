import { useEditorStore } from '../../store/editorStore'
import { Switch } from '../ui/switch'
import { Moon, Sun } from 'tabler-icons-react'
import { useShallow } from 'zustand/react/shallow'

export function GeneralTab() {
  const { mode, toggleMode } = useEditorStore(
    useShallow((state) => ({
      mode: state.mode,
      toggleMode: state.toggleMode,
    })),
  )

  return (
    <div className="p-8">
      <h2 className="text-lg font-semibold text-foreground mb-6">General Settings</h2>

      <div className="space-y-8">
        {/* Mode Setting */}
        <div className="flex items-center justify-between p-4 bg-muted/50 rounded-lg border border-border">
          <div>
            <h3 className="font-medium text-foreground">Appearance</h3>
            <p className="text-sm text-muted-foreground">Switch between light and dark mode.</p>
          </div>
          <div className="flex items-center gap-3">
            <Sun className="w-5 h-5 text-muted-foreground" />
            <Switch checked={mode === 'dark'} onCheckedChange={toggleMode} />
            <Moon className="w-5 h-5 text-muted-foreground" />
          </div>
        </div>
      </div>
    </div>
  )
}
